// Android 実機のタイル(vscode-fleetest)が「ブリッジ未起動」を出せるようにするための、
// ブリッジを**起動せずに**生死だけを見る信号(`AndroidDriver.isBridgeRunning`)の固定。
//
// `bridgeRunningVerdict` は `pidof` の Shell.Result から Bool? を作る純関数(実 adb は叩かない)。
// 取得できない(nil)ときに false へ丸めないことを守る —— 丸めると `api monitor` 側が
// 「観測できない」を「ブリッジが無い」と誤って断定し、絵が消える。

import XCTest
@testable import FTAndroid
@testable import FTCore

final class AndroidBridgeRunningProbeTests: XCTestCase {

    func testNilResultIsUnknownNotFalse() {
        XCTAssertNil(AndroidDriver.bridgeRunningVerdict(nil),
                     "adb が失敗/timeout したときは「不明」(nil)であって false ではない")
    }

    func testNonEmptyPidofOutputIsRunning() {
        XCTAssertEqual(AndroidDriver.bridgeRunningVerdict(Shell.Result(status: 0, output: "12345\n")), true)
    }

    func testEmptyPidofOutputIsNotRunning() {
        XCTAssertEqual(AndroidDriver.bridgeRunningVerdict(Shell.Result(status: 1, output: "")), false)
    }

    func testWhitespaceOnlyPidofOutputIsNotRunning() {
        XCTAssertEqual(AndroidDriver.bridgeRunningVerdict(Shell.Result(status: 0, output: "\n")), false)
    }

    /// adb 自体が失敗した(オフライン等)ときの非数字のエラー文言を pid と誤認して
    /// 「動いている」と断定しない —— pidof は「見つからない」でも非ゼロで終わるため、
    /// status だけでは adb の失敗と区別できない(§56.10 と同じ型)
    func testNonNumericOutputIsUnknownNotRunning() {
        XCTAssertNil(AndroidDriver.bridgeRunningVerdict(
            Shell.Result(status: 1, output: "error: no devices/emulators found")))
    }

    func testMultiplePidsAreStillRunning() {
        XCTAssertEqual(AndroidDriver.bridgeRunningVerdict(Shell.Result(status: 0, output: "123 456\n")), true)
    }
}

/// doctor / bridge status の「導入済みの版」の読み。**読めなかったこと(adb 失敗・期限切れ)を
/// 「未導入」に畳まない** —— 畳むと凍結・切断した端末に「初回操作で自動導入される」と言う
final class AndroidBridgeInstalledVersionReadingTests: XCTestCase {

    func testVersionCodeIsInstalled() {
        XCTAssertEqual(AndroidDriver.installedVersionReading(
            Shell.Result(status: 0, output: "Packages:\n    versionCode=85 minSdk=26 targetSdk=34\n")),
            .installed(85))
    }

    func testUnableToFindPackageIsNotInstalled() {
        XCTAssertEqual(AndroidDriver.installedVersionReading(
            Shell.Result(status: 0, output: "Unable to find package: com.example.ftbridge\nDomain verification status:\n")),
            .notInstalled)
    }

    func testNoResultIsUnknown() {
        XCTAssertEqual(AndroidDriver.installedVersionReading(nil), .unknown)
    }

    func testAdbFailureIsUnknownNotNotInstalled() {
        XCTAssertEqual(AndroidDriver.installedVersionReading(
            Shell.Result(status: 1, output: "error: device offline")), .unknown)
    }

    /// 終了コード 0 でも、版も「見つからない」も無い出力は判定できない
    func testUnrecognisedOutputIsUnknown() {
        XCTAssertEqual(AndroidDriver.installedVersionReading(Shell.Result(status: 0, output: "")), .unknown)
    }
}

/// doctor のアニメーション警告。**読めなかった key を「ON」と言わず、黙りもしない**
final class AndroidAnimationScaleWarningTests: XCTestCase {

    func testAllZeroIsSilent() {
        XCTAssertNil(AndroidDriver.animationScaleWarning(readings: [("a", "0"), ("b", "0.0\n")]))
    }

    func testNullIsTheDefaultOneAndWarnsAsOn() {
        let warning = AndroidDriver.animationScaleWarning(readings: [("a", "null"), ("b", "0")])
        XCTAssertEqual(warning?.contains("animation settings are on (a)"), true)
    }

    func testUnreadKeyIsReportedButNotCalledOn() throws {
        let warning = try XCTUnwrap(AndroidDriver.animationScaleWarning(readings: [("a", nil), ("b", "0")]),
                                    "読めない key を黙って飛ばしている")
        XCTAssertFalse(warning.contains("are on"), "読めない key を「ON」と断定している")
        XCTAssertTrue(warning.contains("could not read the animation settings (a)"))
    }
}

/// `isBridgeRunning` / `pidofResult` が `ensureBridge()` / `startBridge()` を呼んでいないことの
/// ソース走査(観測がブリッジを起動する副作用を復活させないための固定)。方針は
/// `ApiMonitorAndroidCaptureSourceScanTests` と同じ(コメント除去 → 関数本体を切り出し→正規表現)。
final class AndroidBridgeRunningProbeSourceScanTests: XCTestCase {

    private static var androidBridgeSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FTAndroidTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Sources/FTAndroid/AndroidBridge.swift")
    }

    private static func codeOnly(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//")[0] }
            .joined(separator: "\n")
    }

    /// `funcName` 本体(次の `\n    }`(4スペース閉じ = メンバ関数の終端)まで)を切り出す。
    /// この方式は入れ子ブロックを正確には追わないが、対象2関数はどちらもガード節+1行の
    /// 単純な本体で誤検出の余地がない
    private static func functionBody(_ funcName: String, in code: String) -> String? {
        guard let startRange = code.range(of: "func \(funcName)") else { return nil }
        guard let braceStart = code.range(of: "{", range: startRange.upperBound..<code.endIndex) else { return nil }
        guard let endRange = code.range(of: "\n    }", range: braceStart.upperBound..<code.endIndex) else {
            return nil
        }
        return String(code[braceStart.upperBound..<endRange.lowerBound])
    }

    func testIsBridgeRunningDoesNotCallEnsureBridge() throws {
        let code = try Self.codeOnly(Self.androidBridgeSource)
        guard let body = Self.functionBody("isBridgeRunning", in: code) else {
            XCTFail("isBridgeRunning が見当たらない(走査対象のパス解決を疑う)")
            return
        }
        XCTAssertFalse(body.contains("ensureBridge"),
                       "isBridgeRunning が ensureBridge() を通している。観測はブリッジを起動してはいけない")
        XCTAssertFalse(body.contains("startBridge"),
                       "isBridgeRunning が startBridge() を通している。観測はブリッジを起動してはいけない")
    }

    func testPidofResultDoesNotCallEnsureBridge() throws {
        let code = try Self.codeOnly(Self.androidBridgeSource)
        guard let body = Self.functionBody("pidofResult", in: code) else {
            XCTFail("pidofResult が見当たらない(走査対象のパス解決を疑う)")
            return
        }
        XCTAssertFalse(body.contains("ensureBridge"))
        XCTAssertFalse(body.contains("startBridge"))
    }

    /// 走査が空振りしていないことの確認(パス解決がズレて0件のまま緑になるのを防ぐ)
    func testTheSourceFileIsActuallyScanned() throws {
        let code = try Self.codeOnly(Self.androidBridgeSource)
        XCTAssertTrue(code.contains("func isBridgeRunning"),
                      "isBridgeRunning が見当たらない(走査対象のパス解決を疑う)")
    }
}
