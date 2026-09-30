import XCTest
@testable import fleetest

/// ライブ操作(シミュレータ)の自動起動は、同じ台の別ポートに残ったランナーの残骸を起動より前に止める
/// (負荷テスト: serve の再起動のたびに別ポートへ建て、待受の無い xcodebuild が台ごとに溜まった)。
final class ApiLiveLeftoverRunnerReapTests: XCTestCase {

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
