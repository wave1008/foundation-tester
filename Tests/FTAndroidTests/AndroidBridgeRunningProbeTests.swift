// Android 実機のタイル(vscode-fleetest)が「ブリッジ未起動」を出せるようにするための、
// ブリッジを**建てずに**生死だけを見る信号(`AndroidDriver.isBridgeRunning`)の固定。
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
}

/// `isBridgeRunning` / `pidofResult` が `ensureBridge()` / `startBridge()` を呼んでいないことの
/// ソース走査(観測がブリッジを建てる副作用を復活させないための固定)。方針は
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
                       "isBridgeRunning が ensureBridge() を通している。観測はブリッジを建ててはいけない")
        XCTAssertFalse(body.contains("startBridge"),
                       "isBridgeRunning が startBridge() を通している。観測はブリッジを建ててはいけない")
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
