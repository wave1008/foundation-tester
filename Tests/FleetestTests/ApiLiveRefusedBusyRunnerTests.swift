import XCTest
@testable import fleetest

/// ライブ操作の接続拒否: **listener の実体が居るなら自動起動を撃たない**。
/// 実測(負荷テスト): a11y の再試行で数十秒塞がった XCUITest ランナーは backlog(16)が溢れて生きたまま
/// connect を断り、自動起動の前処理(leftover の片付け)がそのランナーを殺して建て直していた
/// (ランナーのログは異常終了なしの BUILD INTERRUPTED だけ)。
final class ApiLiveRefusedBusyRunnerTests: XCTestCase {

    func testRefusedWithALiveListenerIsBusyNotAStartTrigger() {
        XCTAssertEqual(ApiLiveServe.refusedGuidance(triggering: true, listenerAlive: true), .busy)
        XCTAssertEqual(ApiLiveServe.refusedGuidance(triggering: true, listenerAlive: false), .triggerStarter)
        XCTAssertEqual(ApiLiveServe.refusedGuidance(triggering: false, listenerAlive: false), .starterSuffix)
        XCTAssertEqual(ApiLiveServe.refusedGuidance(triggering: false, listenerAlive: true), .starterSuffix)
    }

    /// annotated の拒否の分岐が listener を確かめてから決めること(判定を呼ばずに noteConnectionRefused へ戻す変異を落とす)
    func testAnnotatedConsultsTheListenerBeforeTriggering() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        guard let start = code.range(of: "private func annotated("),
              let refused = code.range(of: "case DriverError.bridgeConnectionRefused = error",
                                       range: start.upperBound..<code.endIndex),
              let end = code.range(of: "return message", range: refused.upperBound..<code.endIndex) else {
            return XCTFail("annotated の拒否の分岐が見当たらない")
        }
        let branch = String(code[refused.upperBound..<end.lowerBound])
        XCTAssertTrue(branch.contains("BridgeDiscovery.refusedButListenerAlive("), branch)
        XCTAssertTrue(branch.contains("Self.refusedGuidance("), branch)
        XCTAssertEqual(branch.components(separatedBy: "noteConnectionRefused()").count - 1, 1, branch)
    }

    /// シミュレータの自動起動は、同じ台の別ポートに残ったランナーの残骸(待受が拒否 = 誰も居ない)を
    /// 起動より前に止める(実測: serve の再起動のたびに別ポートへ建て、待受の無い xcodebuild が台ごとに溜まった)。
    /// 止める条件を `.refused` 以外へ広げる変異(生きたランナーを殺す)と、片付けを消す変異を落とす
    func testAutoStartReapsOnlyRefusedLeftoverRunnersBeforeStarting() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/LiveBridgeAutoStarter.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        guard let reap = code.range(of: "BridgeLauncher.runnersOnDevice(psOutput: ps.output, device: udid, excludingPort: port)\n"),
              let start = code.range(of: "try launcher.startDetached()") else {
            return XCTFail("残骸の片付けか起動が見当たらない")
        }
        XCTAssertLessThan(reap.lowerBound, start.lowerBound)
        let tail = String(code[reap.upperBound...].prefix(200))
        XCTAssertTrue(tail.contains("where BridgeDiscovery.connectProbe(port: other.port, repoRoot: repoRoot) == .refused"), tail)
    }
}
