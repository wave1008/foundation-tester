import XCTest

/// XCUITest ランナーは XCTest の既定の割り込みハンドラを止める(InterruptionGuard)。
/// 既定のハンドラは操作を遮ったシステムアラートのボタンを押し(「許可」も)、遮られた操作を撃ち直す
/// —— 「吸われた操作は撃ち直さない」「登録が無ければ閉じない」に反する(2026-10-03 負荷テストで実測)。
/// ランナーは swift test でビルドされないので、配線はソース走査で縛る(挙動は sim の実地で確認済み:
/// 写真の権限アラート越しの ref / 座標タップ・スワイプが 422 で返り、アラートも権限も変わらない)
final class RunnerInterruptionGuardScanTests: XCTestCase {
    private func runnerSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runner/FleetestRunnerUITests/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// テスト本体が起動時に install する(無いと既定のハンドラが働く)
    func testBridgeTestInstallsTheGuard() throws {
        let code = try runnerSource("FleetestBridgeTests.swift")
        XCTAssertTrue(code.contains("InterruptionGuard.shared.install(on: self)"))
    }

    /// モニタは true だけを返す —— false は既定のハンドラへ落ちる(= ボタンを押して撃ち直す)
    func testMonitorNeverFallsThroughToTheDefaultHandler() throws {
        let code = try runnerSource("InterruptionGuard.swift")
        guard let start = code.range(of: "addUIInterruptionMonitor("),
              let end = code.range(of: "func reset()", range: start.upperBound..<code.endIndex) else {
            return XCTFail("割り込みモニタが見当たらない — テストを見直すこと")
        }
        let body = String(code[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("return true"))
        XCTAssertFalse(body.contains("return false"), "false は既定の割り込みハンドラへ落ちる")
    }

    /// 要求の頭で控えを消し、遮られていたら成功でも失敗でも 422 で名指しする(握りつぶされた issue を 200 にしない)
    func testRouterReportsABlockedActionAs422() throws {
        let code = try runnerSource("BridgeRouter.swift")
        guard let start = code.range(of: "func handle(_ request: BridgeHTTPServer.Request)"),
              let end = code.range(of: "// MARK: - Handlers", range: start.upperBound..<code.endIndex) else {
            return XCTFail("BridgeRouter.handle が見当たらない — テストを見直すこと")
        }
        let body = String(code[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("-> BridgeHTTPServer.Response {\n        InterruptionGuard.shared.reset()\n"),
                      "要求の頭で控えを消していない(前の要求の控えが次の要求を 422 にする)")
        XCTAssertEqual(body.components(separatedBy: "InterruptionGuard.shared.take()").count - 1, 3,
                       "成功の経路と2つの catch の全部で控えを見ること")
        XCTAssertEqual(body.components(separatedBy: "status: 422)").count - 1, 3)
    }
}
