// 答えないランナーの回復の階段(再起動 → 初期化)の配線をソース走査で固定する。
// 供給そのものは実デバイスを要求するので、純粋関数(RunnerAccessibilityHealthTests)で決められない
// 「その判定を実際に通っているか」だけをここで見る。

import XCTest

final class RunnerRecoveryLadderWiringTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func compact(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// 起動し直しが効いたかは restartHelped だけが決める(`guard let after, isDegraded` の形へ戻すと、
    /// 答えなかった・測れなかったが「直った」に数えられる)
    func testRestartsDecideHelpedOnlyThroughRestartHelped() throws {
        let text = compact(try source("Sources/FTBridgeClient/BridgeProvisioner.swift"))
        XCTAssertEqual(text.components(separatedBy: compact("RunnerAccessibilityHealth.restartHelped(after: after)")).count - 1, 2)
        XCTAssertFalse(text.contains(compact("guardletafter,RunnerAccessibilityHealth.isDegraded")))
    }

    /// 起動し直しても答えないデバイスは、供給では離脱させ(failIfNotAnswering)、
    /// 通常の再利用の分岐・はしごの終端の両方で通す
    func testNotAnsweringDeviceIsFailedInTheSupply() throws {
        let text = compact(try source("Sources/FTBridgeClient/BridgeProvisioner.swift"))
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: compact("try failIfNotAnswering(")).count - 1, 3)
    }

    /// 初期化は SimulatorEraseForRecovery の1箇所を通り、erase を撃つ直前の門(wipeBlock)なしには呼ばれない
    func testEraseIsGatedByWipeBlock() throws {
        let text = compact(try source("Sources/FTBridgeClient/BridgeProvisioner.swift"))
        XCTAssertEqual(text.components(separatedBy: compact("SimulatorEraseForRecovery.erase(")).count - 1, 1)
        // 初期化へ進む分岐は block == nil のときだけ(guard block == nil else { …再起動止まり… })
        XCTAssertTrue(text.contains(compact("guard block == nil else {")))
    }

    /// 消したアプリを入れ直す呼び手だけが初期化を許す。許す呼び手は既定の false から明示で上げる
    func testOnlyReinstallingCallersMayErase() throws {
        let provisioner = compact(try source("Sources/FTBridgeClient/BridgeProvisioner.swift"))
        XCTAssertTrue(provisioner.contains(compact("mayEraseSimulatorForRecovery: Bool = false")))
        let lanes = try source("Sources/fleetest/ProfileSupplyLanes.swift")
        XCTAssertTrue(lanes.contains("mayEraseSimulatorForRecovery: true"))
        let factory = try source("Sources/FTAndroid/ProfileWorkerFactory.swift")
        XCTAssertEqual(factory.components(separatedBy: "mayEraseSimulatorForRecovery: true").count - 1, 2,
                       "復帰(buildWorker)と凍結回復の張り直しだけが許す")
    }

    /// 初期化は必ず SimulatorBoot.ensureBooted(同時起動の枠)で起動し、終了コードを見る
    func testEraseChecksExitCodeAndBootsThroughTheSingleEntry() throws {
        let text = compact(try source("Sources/FTBridgeClient/SimulatorEraseForRecovery.swift"))
        XCTAssertTrue(text.contains(compact("SimulatorBoot.ensureBooted(udid: udid, log: log)")))
        XCTAssertTrue(text.contains(compact("guard result.status == 0 else")))
        XCTAssertFalse(text.contains(compact("\"boot\"")), "simctl boot を直接撃たない")
    }

    /// ワーカー復帰は答えないデバイスを通さない
    func testReviveWorkerConsultsTheGate() throws {
        let text = compact(try source("Sources/fleetest/ProfileRunOrchestrator.swift"))
        XCTAssertTrue(text.contains(compact(
            "RunnerAccessibilityHealth.shouldReviveWorker(udid: retired.connection.udid, futility: .shared)")))
    }

    /// 中途の測り直しが「答えない」を見たらレーンを離脱させる(orchestrator が .unusable を処理する)
    func testMidRunRecheckRetiresAnUnusableLane() throws {
        let orchestrator = compact(try source("Sources/FTCore/RunOrchestrator.swift"))
        XCTAssertTrue(orchestrator.contains(compact("case .unusable(let reason):")))
        let recheck = compact(try source("Sources/fleetest/RunnerMidRunRecheck.swift"))
        XCTAssertTrue(recheck.contains(compact("case .unusable(let waited):")))
    }
}
