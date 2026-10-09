import XCTest

/// XCUITest ランナーの `X-FT-Settle: 0` の扱い(ランナーは XCUITest の中でしか動かないのでソースで固定する)。
/// 契約は BridgeRouter.skipSettle の doc: ヘッダは「この操作の後の整定」を外すだけで、
/// **前の操作が予約した整定(settlePending)を GET /snapshot で打ち消してはならない**。
final class RunnerSettleHeaderScanTests: XCTestCase {
    private func runnerSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runner/FleetestRunnerUITests/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSnapshotHonoursThePendingSettleRegardlessOfTheHeader() throws {
        let code = try runnerSource("BridgeRouter.swift")
        XCTAssertTrue(code.contains("let cap = try settlePending ? captureSettled(app) : captureOnce(app)"))
        XCTAssertTrue(code.contains("let cap = try settlePending ? captureSettled(springboard) : captureOnce(springboard)"))
        XCTAssertFalse(code.contains("settlePending && !skipSettle"),
                       "settle: false のステップが前の操作の整定を打ち消す")
    }

    func testSettleFalseActionDoesNotReserveTheSettle() throws {
        let code = try runnerSource("BridgeRouter.swift")
        XCTAssertTrue(code.contains("Self.mutatingPaths.contains(request.path), !skipSettle {"),
                      "settle: false の操作が settlePending を立てている")
    }
}
