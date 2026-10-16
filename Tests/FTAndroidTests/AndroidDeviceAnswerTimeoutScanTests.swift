// 凍結した端末(adb devices には device のまま載り、`adb shell` が返らない)に、期限なしの
// `adb shell` を撃つ経路を増やさないための走査。期限が無いと1台の凍結が呼び手全体を握る ——
// MCP は呼び出しを順に処理するので、**他の健全な端末への呼び出しまで**返らなくなる(実地で確認)。
//
// 短く返るはずの命令は `adbAnswering`(期限つき)を、長さが読めない命令は入口で
// `requireDeviceAnswers()` を通す。ブリッジのコールド起動は最初の問い合わせが期限つきの門。

import XCTest

final class AndroidDeviceAnswerTimeoutScanTests: XCTestCase {

    private static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTAndroid/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }

    /// 短い命令(keyevent・dumpsys window・settings・force-stop・pm list)を AndroidDriver が素の `adb(` で撃たない
    func testShortDeviceCommandsInTheDriverAreBounded() throws {
        let text = try Self.source("AndroidDriver.swift")
        let unbounded = [
            #"adb(["shell", "input", "keyevent""#,
            #"adb(["shell", "dumpsys", "window""#,
            #"adb(["shell", "settings""#,
            #"adb(["shell", "am", "force-stop""#,
            #"adb(["shell", "pm", "list""#,
        ].filter { text.contains($0) }
        XCTAssertEqual(unbounded, [], "期限なしで端末へ撃つ短い命令がある(adbAnswering / adbProbe を通す)")
        XCTAssertTrue(text.contains("adbAnswering(["), "走査の前提(期限つきの呼び出し)が見つからない")
    }

    /// 素の `adb([`(期限なし)の呼び出しを**全部拾い**、同じ関数の手前に `requireDeviceAnswers()` があるか、
    /// 理由つきの免除表に載っているかを見る。禁止形の列挙だけだと新しい形(monkey・wm density・uninstall)が
    /// すり抜けた(凍結しかけた Emulator への `ft_launch resume:true` が monkey で 240 秒返らなかった)
    func testEveryUnboundedAdbCallInTheDriverIsGatedOrExempted() throws {
        let text = try Self.source("AndroidDriver.swift")
        // 免除 = 端末の応答を確かめずに撃つと決めたもの(等号で固定する。足すなら理由を書く)
        let exempted: [String: String] = [
            #"adb(["shell", "input", "swipe""#:
                "ドラッグ・長押しのフォールバック(実機の主経路)。正当に長く、門の往復を毎ジェスチャに払わない(§65.6)",
        ]
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z])adb\(\[[^\]\n]*"#)
        let ns = text as NSString
        var ungated: [String] = []
        var exemptHits = Set<String>()
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let call = ns.substring(with: match.range)
            if let key = exempted.keys.first(where: { call.hasPrefix($0) }) {
                exemptHits.insert(key)
                continue
            }
            let before = ns.substring(to: match.range.location)
            guard let funcStart = before.range(of: "func ", options: .backwards) else {
                ungated.append(call); continue
            }
            if !before[funcStart.lowerBound...].contains("requireDeviceAnswers()") {
                ungated.append(call)
            }
        }
        XCTAssertEqual(ungated, [], "期限なしの adb を門なしで撃つ経路がある(短い命令は adbAnswering、長い命令は入口で requireDeviceAnswers)")
        XCTAssertEqual(exemptHits, Set(exempted.keys), "免除表に、もう存在しない呼び出しが残っている")
        XCTAssertGreaterThan(regex.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length)), 5,
                             "走査の前提(素の adb の呼び出し)が見つからない")
    }

    /// `pm clear` は所要が読めないので、入口で1回 端末が答えるかを確かめること
    func testClearAppDataChecksTheDeviceAnswersFirst() throws {
        let text = try Self.source("AndroidDriver.swift")
        let start = try XCTUnwrap(text.range(of: "public func clearAppData(bundleID: String) async throws {"))
        let body = text[start.upperBound...].prefix(200)
        let gate = try XCTUnwrap(body.range(of: "try requireDeviceAnswers()"), "clearAppData に門が無い")
        let clear = try XCTUnwrap(body.range(of: #"adb(["shell", "pm", "clear""#))
        XCTAssertLessThan(gate.lowerBound, clear.lowerBound)
    }

    /// ブリッジのコールド起動の最初の問い合わせは期限つき(続く段 = 設定・install・起動はその後ろ)
    func testBridgeColdStartIsGatedByABoundedProbe() throws {
        let text = try Self.source("AndroidBridge.swift")
        let gate = try XCTUnwrap(text.range(of: #"probe = try adbProbe(["shell", "settings", "get", "global", "window_animation_scale"],"#),
                                 "コールド起動の門が期限つきの問い合わせになっていない")
        let firstStage = try XCTUnwrap(text.range(of: "noticePersistentSettingsOnPhysicalDevice()\n        disableAnimations()"))
        XCTAssertLessThan(gate.lowerBound, firstStage.lowerBound)
        XCTAssertTrue(text.contains("} catch ShellError.timedOut {"), "期限切れを「端末が答えない」として断っていない")
    }
}
