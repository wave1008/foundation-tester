import XCTest
@testable import FTAndroid
@testable import FTBridgeClient

/// 「その台を他人が使っているか」の判定は**2箇所にある**: 台を止める操作の門
/// (`DeviceBooter.deviceInUseRefusal`)と、遅いランナーの台ごと再起動の門
/// (`RunnerAccessibilityHealth.hasForeignLease`)。FTAndroid → FTBridgeClient の依存方向のため
/// あちらからこちらを呼べず関数を共有できないので、**答えが割れたらここで落とす**。
/// 割れると同じ台に対して「止めるのは断る」のに「再起動はする」が同時に成り立つ。
final class LeaseJudgementAgreementTests: XCTestCase {
    func testBothGatesAgreeOnEveryHolderCombination() {
        let selfPID: Int32 = 4242
        let other: Int32 = 9999
        let combinations: [(run: Int32?, mcp: Int32?)] = [
            (nil, nil), (other, nil), (nil, other), (other, other),
            (selfPID, nil),      // 自分の run-lease は「他人が使用中」ではない
            (selfPID, other),
        ]
        for combination in combinations {
            let refusedByStopGate = DeviceBooter.stopRefusal(
                deviceName: "d", keys: ["k"], selfPID: selfPID, force: false,
                holderPID: { _ in combination.run }) != nil
                || DeviceBooter.mcpStopRefusal(
                    deviceName: "d", keys: ["k"], force: false,
                    mcpHolderPID: { _ in combination.mcp }) != nil
            let foreignByRestartGate = RunnerAccessibilityHealth.hasForeignLease(
                runLeaseHolder: combination.run, mcpLeaseHolder: combination.mcp, selfPID: selfPID)
            XCTAssertEqual(refusedByStopGate, foreignByRestartGate,
                           "run=\(String(describing: combination.run))"
                               + " mcp=\(String(describing: combination.mcp)) で判定が割れた")
        }
    }
}
