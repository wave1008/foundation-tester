import XCTest
@testable import FTBridgeClient

/// ライブ操作の自動起動の門: 同じ端末の別ポートに**待受しているランナー**が居れば2本目を起動しない。
/// 忙しいランナーは /status に答えず走査に載らないが、待受は続く(`.refused` だけが「居ない」の確定証拠)。
final class SimulatorRunnerElsewhereGateTests: XCTestCase {

    private let busy: (pid: Int32, port: UInt16) = (101, 8129)
    private let gone: (pid: Int32, port: UInt16) = (102, 8130)

    func testListeningRunnerIsLiveSoNoSecondRunnerIsStarted() {
        let split = BridgeLauncher.partitionRunnersElsewhere([busy], connect: { _ in .connected })
        XCTAssertEqual(split.live.map(\.port), [8129])
        XCTAssertTrue(split.leftovers.isEmpty)
    }

    /// 溢れた backlog の reset や 300ms の時間切れ(.unknown)は「居るかもしれない」= live
    func testUnknownProbeCountsAsLive() {
        let split = BridgeLauncher.partitionRunnersElsewhere([busy], connect: { _ in .unknown })
        XCTAssertEqual(split.live.map(\.port), [8129])
    }

    /// 接続拒否が確定したものだけ残骸(止めてよい)
    func testRefusedRunnerIsALeftoverNotLive() {
        let split = BridgeLauncher.partitionRunnersElsewhere(
            [busy, gone], connect: { $0 == 8130 ? .refused : .connected })
        XCTAssertEqual(split.live.map(\.port), [8129])
        XCTAssertEqual(split.leftovers.map(\.port), [8130])
    }

    func testNoOtherRunnersMeansNothingBlocks() {
        let split = BridgeLauncher.partitionRunnersElsewhere([], connect: { _ in .connected })
        XCTAssertTrue(split.live.isEmpty && split.leftovers.isEmpty)
    }

    func testMessageReadsCorrectlyForSimulatorAndPhysical() {
        let sim = LauncherError.deviceRunnerElsewhere(device: "UD-1", port: 8129, pid: 5, physical: false)
            .errorDescription ?? ""
        XCTAssertTrue(sim.hasPrefix("simulator UD-1"), sim)
        XCTAssertFalse(sim.contains("physical device"), sim)
        XCTAssertTrue(sim.contains("fleetest bridge down --port 8129"), sim)
        let phys = LauncherError.deviceRunnerElsewhere(device: "UD-2", port: 8150, pid: 6, physical: true)
            .errorDescription ?? ""
        XCTAssertTrue(phys.hasPrefix("physical device UD-2"), phys)
    }
}
