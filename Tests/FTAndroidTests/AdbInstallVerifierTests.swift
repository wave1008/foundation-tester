// `adb install` の検証(Play Protect)を install の間だけ切って戻す門の固定。
// 実測の根拠は AdbInstallVerifier の冒頭(Pixel 4a・Android 13・2026-09-05)。

import XCTest
@testable import FTAndroid
@testable import FTCore

final class AdbInstallVerifierTests: XCTestCase {

    // 端末単位の錠(withDeviceLock)は既定で `~/.fleetest` を触るため、テストは自分専用の
    // 一時ディレクトリへ差し替える(FMLock の lockDirectoryForTesting と同じ規律)。
    // メソッドはこのクラス内で直列に走る前提(CLAUDE.md: 並列はプロセスを分ける)なので
    // static var の差し替えで足りる
    private var lockDir: URL!

    override func setUp() {
        super.setUp()
        lockDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdbInstallVerifierTests-\(UUID().uuidString)", isDirectory: true)
        AdbInstallVerifier.lockDirectoryForTesting = lockDir
    }

    override func tearDown() {
        AdbInstallVerifier.lockDirectoryForTesting = nil
        if let lockDir { try? FileManager.default.removeItem(at: lockDir) }
        super.tearDown()
    }

    /// 未設定("null")は put で "null" を書かず delete で既定へ戻す
    func testRestoreDeletesTheKeyWhenItWasUnset() {
        XCTAssertEqual(AdbInstallVerifier.restoreArguments(original: "null\n"),
                       ["shell", "settings", "delete", "global", "verifier_verify_adb_installs"])
        XCTAssertEqual(AdbInstallVerifier.restoreArguments(original: ""),
                       ["shell", "settings", "delete", "global", "verifier_verify_adb_installs"])
    }

    func testRestorePutsTheOriginalValueBack() {
        XCTAssertEqual(AdbInstallVerifier.restoreArguments(original: "1\n"),
                       ["shell", "settings", "put", "global", "verifier_verify_adb_installs", "1"])
    }

    /// 切る → body → 戻す、の順で adb が呼ばれ、body の例外でも戻す
    func testDisablesAroundTheBodyAndRestoresEvenWhenTheBodyThrows() {
        var calls: [[String]] = []
        func adb(_ args: [String]) throws -> Shell.Result {
            calls.append(args)
            let output = args.contains("get") ? "null\n" : ""
            return Shell.Result(status: 0, output: output)
        }
        struct Boom: Error {}
        XCTAssertThrowsError(try AdbInstallVerifier.withVerificationOff(adb: adb) { throw Boom() })
        XCTAssertEqual(calls, [
            ["get-serialno"],
            AdbInstallVerifier.readArguments,
            AdbInstallVerifier.disableArguments,
            AdbInstallVerifier.restoreArguments(original: "null"),
        ])
    }

    /// 既に 0 なら触らない(戻す必要も無い)
    func testLeavesTheSettingAloneWhenAlreadyOff() throws {
        var calls: [[String]] = []
        let value = try AdbInstallVerifier.withVerificationOff(adb: { args in
            calls.append(args); return Shell.Result(status: 0, output: "0\n")
        }) { 42 }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(calls, [["get-serialno"], AdbInstallVerifier.readArguments])
    }

    /// 読めなければ切らずに body だけ(設定を壊す側に倒さない)
    func testRunsTheBodyWithoutTouchingTheSettingWhenTheReadFails() throws {
        var calls: [[String]] = []
        _ = try AdbInstallVerifier.withVerificationOff(adb: { args in
            calls.append(args); return Shell.Result(status: 1, output: "")
        }) { () }
        XCTAssertEqual(calls, [["get-serialno"], AdbInstallVerifier.readArguments])
    }

    /// Wi-Fi 接続の serial(`:` を含む)はファイル名に安全な形へ潰す
    func testSanitizedForLockFilenameEscapesPathLikeCharacters() {
        XCTAssertEqual(AdbInstallVerifier.sanitizedForLockFilename("192.168.1.23:5555"), "192.168.1.23_5555")
        XCTAssertEqual(AdbInstallVerifier.sanitizedForLockFilename("emulator-5554"), "emulator-5554")
    }

    /// `get-serialno` が失敗/空を返しても丸めた1本の鍵に倒す(取り違えて競合を許すより安全)
    func testDeviceLockKeyFallsBackWhenSerialCannotBeRead() {
        XCTAssertEqual(AdbInstallVerifier.deviceLockKey(run: { _ in (1, "") }), "unknown-device")
        XCTAssertEqual(AdbInstallVerifier.deviceLockKey(run: { _ in (0, "  \n") }), "unknown-device")
        XCTAssertEqual(AdbInstallVerifier.deviceLockKey(run: { _ in (0, "ABC123\n") }), "ABC123")
    }

    /// **本題の回帰**: 同じ端末(同じ get-serialno)への2つの install が重ならず直列化される。
    /// 錠が無いと、片方の restore がもう片方の install の途中で発火して検証を再び有効化しうる
    /// (§3 要調査の実害)。この検知は「body の実行区間が重ならない」で行う ——
    /// 錠が効いていなければ DispatchQueue.global() の2並列でほぼ確実に重なる
    func testConcurrentInstallsOnTheSameDeviceAreSerialized() {
        final class Overlap: @unchecked Sendable {
            private let lock = NSLock()
            private var inside = false
            private(set) var sawOverlap = false
            func enter() { lock.lock(); if inside { sawOverlap = true }; inside = true; lock.unlock() }
            func exit() { lock.lock(); inside = false; lock.unlock() }
        }
        let overlap = Overlap()
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                _ = try? AdbInstallVerifier.withVerificationOff(run: { args in
                    if args == ["get-serialno"] { return (0, "same-device\n") }
                    if args == AdbInstallVerifier.readArguments { return (0, "1\n") }
                    return (0, "")
                }) {
                    overlap.enter()
                    Thread.sleep(forTimeInterval: 0.05)
                    overlap.exit()
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertFalse(overlap.sawOverlap, "同じ端末への2つの install の body が重なった(直列化できていない)")
    }

    /// 別の端末(別 serial)は互いを待たない ——  端末単位であって全体を1本に潰していないことの確認
    func testDifferentDevicesAreNotSerializedAgainstEachOther() {
        final class Overlap: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            private(set) var sawBothInsideAtOnce = false
            func enter() { lock.lock(); count += 1; if count == 2 { sawBothInsideAtOnce = true }; lock.unlock() }
            func exit() { lock.lock(); count -= 1; lock.unlock() }
        }
        let overlap = Overlap()
        let group = DispatchGroup()
        for serial in ["device-a", "device-b"] {
            group.enter()
            DispatchQueue.global().async {
                _ = try? AdbInstallVerifier.withVerificationOff(run: { args in
                    if args == ["get-serialno"] { return (0, "\(serial)\n") }
                    if args == AdbInstallVerifier.readArguments { return (0, "1\n") }
                    return (0, "")
                }) {
                    overlap.enter()
                    Thread.sleep(forTimeInterval: 0.2)
                    overlap.exit()
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertTrue(overlap.sawBothInsideAtOnce, "別々の端末なのに直列化されてしまっている(鍵が端末単位になっていない)")
    }

    /// キルスイッチ(FT_PLAY_PROTECT_BYPASS=0)は端末に1バイトも書かない。未設定・"1" はバイパスする
    func testKillSwitchLeavesTheDeviceUntouched() throws {
        var calls: [[String]] = []
        let value = try AdbInstallVerifier.withVerificationOff(run: { args in
            calls.append(args); return (0, "null")
        }, body: { 7 }, environment: ["FT_PLAY_PROTECT_BYPASS": "0"])
        XCTAssertEqual(value, 7)
        XCTAssertEqual(calls, [], "キルスイッチが効いているのに adb を叩いた")
        XCTAssertTrue(AdbInstallVerifier.bypassEnabled(environment: [:]), "未設定はバイパスする(送らない側)")
        XCTAssertTrue(AdbInstallVerifier.bypassEnabled(environment: ["FT_PLAY_PROTECT_BYPASS": "1"]))
        XCTAssertFalse(AdbInstallVerifier.bypassEnabled(environment: ["FT_PLAY_PROTECT_BYPASS": "false"]))
    }

    /// 配線の固定: プロファイルの `playProtectBypass` を環境変数へ渡す4経路(run / api run / MCP の
    /// profile 解決 / ProfileRunner)がどれも `FTCore.RunEnvironment.apply` を通る(キルスイッチを
    /// "0" で書くのはそちらの1箇所。`RunEnvironmentTests` が固定)。**素の setenv に戻さない**
    func testEveryProfileEntryPointInjectsTheKillSwitch() throws {
        for file in ["fleetest/ProfileRunner.swift", "fleetest/ApiRunCommand.swift",
                     "fleetest/Fleetest.swift", "fleetest-mcp/MCPServer+Dispatch.swift"] {
            let source = try String(contentsOf: sourcesRoot.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains("RunEnvironment.apply("),
                          "\(file) が playProtectBypass を環境変数へ渡していない")
            XCTAssertFalse(source.contains("setenv(AdbInstallVerifier.environmentKey"),
                           "\(file) がキルスイッチを RunEnvironment を通さず直接書いている")
        }
    }

    func testRecognisesEveryInstallShapeAndNothingElse() {
        XCTAssertTrue(AdbInstallVerifier.isInstallCommand(["install", "-r", "/x.apk"]))
        XCTAssertTrue(AdbInstallVerifier.isInstallCommand(["-s", "abc", "install", "/x.apk"]))
        XCTAssertTrue(AdbInstallVerifier.isInstallCommand(["install-multiple", "a.apk", "b.apk"]))
        XCTAssertTrue(AdbInstallVerifier.isInstallCommand(["shell", "pm", "install", "/data/local/tmp/x.apk"]))
        XCTAssertTrue(AdbInstallVerifier.isInstallCommand(["shell", "cmd", "package", "install", "/x.apk"]))
        XCTAssertFalse(AdbInstallVerifier.isInstallCommand(["shell", "pm", "list", "packages"]))
        XCTAssertFalse(AdbInstallVerifier.isInstallCommand(["uninstall", "com.x"]))
        XCTAssertFalse(AdbInstallVerifier.isInstallCommand(["shell", "settings", "get", "global", "verifier_verify_adb_installs"]))
        XCTAssertFalse(AdbInstallVerifier.isInstallCommand([]))
    }

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// **構造の固定**: 門は `AndroidDriver.adb` が引数で掛ける(呼び手の規律に頼らない)
    func testTheAdbHelperItselfAppliesTheGate() throws {
        let source = try String(contentsOf: sourcesRoot.appendingPathComponent("FTAndroid/AndroidDriver.swift"),
                                encoding: .utf8)
        let helper = source.components(separatedBy: "func adb(_ args: [String]) throws -> Shell.Result {")[1]
            .components(separatedBy: "private func rawAdb")[0]
        XCTAssertTrue(helper.contains("AdbInstallVerifier.isInstallCommand(args)"),
                      "AndroidDriver.adb が install 系を門へ通していない")
        XCTAssertTrue(helper.contains("AdbInstallVerifier.withVerificationOff"))
    }

    /// **迂回の固定**: adb で install を打つ Swift はこの3ファイルだけで、素の `Shell.run` /
    /// `Process` から adb install を打つ行は1つも無い。新しい経路を足したら、`AndroidDriver.adb`
    /// を使う(自動で門が掛かる)か、ここに名前を足して `withVerificationOff` を明示するかのどちらか
    func testNoSwiftSourceInstallsOverAdbOutsideTheGate() throws {
        let installLiteral = try NSRegularExpression(pattern: #""install(-multiple|-multi-package)?""#)
        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)!
        var installers: Set<String> = []
        var bypasses: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard installLiteral.firstMatch(in: line, range: range) != nil,
                      line.contains("adb") else { continue }
                installers.insert(url.lastPathComponent)
                if line.contains("Shell.run") || line.contains("Process(") {
                    bypasses.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(bypasses, [], "素の Shell.run / Process で adb install を打っている")
        XCTAssertEqual(installers,
                       ["AndroidDriver.swift", "AndroidBridge.swift", "AndroidWebViewUpdate.swift"],
                       "adb で install を打つファイルが増減した —— 門(AndroidDriver.adb か withVerificationOff)を確かめて更新する")
        // 閉包で adb を受ける側は明示の門が要る
        let webViewUpdate = try String(contentsOf: sourcesRoot.appendingPathComponent("FTAndroid/AndroidWebViewUpdate.swift"),
                                       encoding: .utf8)
        XCTAssertTrue(webViewUpdate.contains("AdbInstallVerifier.withVerificationOff"))
        // bundletool は adb を自分で spawn するので install() 側で明示の門が要る
        let driver = try String(contentsOf: sourcesRoot.appendingPathComponent("FTAndroid/AndroidDriver.swift"),
                                encoding: .utf8)
        let bundle = driver.components(separatedBy: "private func installSplitBundle")[1]
        XCTAssertTrue(bundle.contains("AdbInstallVerifier.withVerificationOff"), "bundletool 経路が門を通っていない")
    }
}
