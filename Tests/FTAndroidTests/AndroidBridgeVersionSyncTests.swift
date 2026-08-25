// AndroidRunner/build.sh の VERSION_CODE・AndroidDriver.expectedBridgeVersionCode・
// コミット済み prebuilt/ftbridge.apk の実版数、の3点同期検証。
// 定数だけ上げて APK の再ビルドを忘れると、ホストは毎回「版不一致」で再インストールを試みるが
// APK 自体が旧版なので永久に一致しない(受け手側で無限に再インストールが走る)。
// 逆に片方の定数だけ上げると、稼働中の旧ブリッジが「版一致」と見なされて再利用され、
// 追加したエンドポイントが 404 になる(dylib 側で同じ形の事故を実際に踏んだ)。
// fleetest api の ProtocolVersion を protocolVersion.test.mjs が守っているのと同じ役割。

import XCTest
import FTAndroid
import FTCore

final class AndroidBridgeVersionSyncTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTAndroidTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// AndroidRunner/build.sh の `VERSION_CODE=<n>` を読む。
    private func buildScriptVersionCode() throws -> Int {
        let script = repoRoot.appendingPathComponent("AndroidRunner/build.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let prefix = "VERSION_CODE="
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: false)
                .first(where: { $0.hasPrefix(prefix) }),
              let value = Int(line.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)) else {
            throw XCTSkip("AndroidRunner/build.sh から VERSION_CODE を読めません")
        }
        return value
    }

    func testBuildScriptVersionCodeMatchesHostConstant() throws {
        XCTAssertEqual(try buildScriptVersionCode(), AndroidDriver.expectedBridgeVersionCode,
                       "AndroidRunner/build.sh の VERSION_CODE と "
                       + "AndroidDriver.expectedBridgeVersionCode は同時に上げること"
                       + "(片方だけだと稼働中の旧ブリッジが再利用され新機能が効かない)")
    }

    /// 無通信 TTL の既定値が Swift(BridgeAPI.bridgeTTLSecondsDefault)と
    /// Java(BridgeInstrumentation.TTL_DEFAULT_SECONDS)で一致するか。
    func testJavaTTLDefaultMatchesHostConstant() throws {
        let java = repoRoot.appendingPathComponent(
            "AndroidRunner/src/com/example/ftbridge/BridgeInstrumentation.java")
        let text = try String(contentsOf: java, encoding: .utf8)
        let pattern = #"TTL_DEFAULT_SECONDS\s*=\s*(\d+)\s*;"#
        guard let match = text.range(of: pattern, options: .regularExpression),
              let value = Int(text[match].replacingOccurrences(
                of: #"[^\d]"#, with: "", options: .regularExpression)) else {
            throw XCTSkip("BridgeInstrumentation.java から TTL_DEFAULT_SECONDS を読めません")
        }
        XCTAssertEqual(value, BridgeAPI.bridgeTTLSecondsDefault,
                       "TTL の既定値は BridgeAPI.bridgeTTLSecondsDefault と "
                       + "BridgeInstrumentation.TTL_DEFAULT_SECONDS を同時に変えること"
                       + "(片方だけだと iOS と Android でゾンビの寿命が食い違う)")
    }

    /// コミット済み APK が定数と同じ版か。上の2定数だけ上げて APK を作り直し忘れる事故を検出する。
    func testPrebuiltAPKVersionMatchesConstants() throws {
        let expected = AndroidDriver.expectedBridgeVersionCode
        let apk = repoRoot.appendingPathComponent("AndroidRunner/prebuilt/ftbridge.apk")
        guard FileManager.default.fileExists(atPath: apk.path) else {
            throw XCTSkip("prebuilt/ftbridge.apk がありません(AndroidRunner/build.sh で生成する)")
        }
        let manifest = try binaryAndroidManifest(inAPK: apk)
        let strings = try axmlStringPool(manifest)

        // versionCode は binary XML 中の整数属性値で文字列プールに出ない。build.sh が
        // `--version-name "1.$VERSION_CODE"` を渡すので、versionName 側を版数の代理として照合する。
        let expectedVersionName = "1.\(expected)"
        XCTAssertTrue(strings.contains(expectedVersionName),
                      "prebuilt/ftbridge.apk の versionName が \(expectedVersionName) ではありません"
                      + "(APK 内の版数文字列: \(strings.filter { $0.hasPrefix("1.") }))。"
                      + "VERSION_CODE / expectedBridgeVersionCode を上げたら "
                      + "AndroidRunner/build.sh を実行して APK を作り直しコミットすること"
                      + "(古い APK のままだとホストが毎回再インストールを試み、永久に版が一致しない)")
    }

    // MARK: - APK / binary AndroidManifest.xml の読み出し
    //
    // aapt2 に依存しない(受け手が Android SDK build-tools を入れているとは限らない)。
    // APK は zip なので /usr/bin/unzip で manifest だけ取り出し、AXML の文字列プールを直接読む。

    private func binaryAndroidManifest(inAPK apk: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", apk.path, "AndroidManifest.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else {
            throw XCTSkip("APK から AndroidManifest.xml を取り出せません(unzip 失敗)")
        }
        return data
    }

    /// AXML(binary XML)の文字列プールを全件返す。
    /// 構造: [XML ヘッダ 8B][文字列プールチャンク: type/headerSize/size, count, styleCount,
    /// flags, stringsStart, stylesStart, オフセット配列…]。UTF-16 なら各要素は u16 長 + UTF-16LE。
    private func axmlStringPool(_ data: Data) throws -> [String] {
        func u16(_ at: Int) throws -> Int {
            guard at + 2 <= data.count else { throw XCTSkip("AXML が壊れています") }
            return Int(data[at]) | Int(data[at + 1]) << 8
        }
        func u32(_ at: Int) throws -> Int {
            guard at + 4 <= data.count else { throw XCTSkip("AXML が壊れています") }
            return Int(data[at]) | Int(data[at + 1]) << 8
                 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24
        }

        guard try u16(0) == 0x0003 else { throw XCTSkip("AXML のマジックが不正です") }
        let pool = 8                                   // 文字列プールチャンクの先頭
        guard try u16(pool) == 0x0001 else { throw XCTSkip("文字列プールが先頭にありません") }
        let count = try u32(pool + 8)
        let isUTF8 = (try u32(pool + 16)) & (1 << 8) != 0
        let stringsStart = try u32(pool + 20)
        let base = pool + stringsStart

        var result: [String] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let p = base + (try u32(pool + 28 + 4 * i))
            if isUTF8 {
                let length = Int(data[p + 1])
                guard p + 2 + length <= data.count else { throw XCTSkip("AXML が壊れています") }
                result.append(String(decoding: data[(p + 2)..<(p + 2 + length)], as: UTF8.self))
            } else {
                let length = try u16(p)
                guard p + 2 + length * 2 <= data.count else { throw XCTSkip("AXML が壊れています") }
                let units = stride(from: p + 2, to: p + 2 + length * 2, by: 2).map {
                    UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8
                }
                result.append(String(decoding: units, as: UTF16.self))
            }
        }
        return result
    }
}
