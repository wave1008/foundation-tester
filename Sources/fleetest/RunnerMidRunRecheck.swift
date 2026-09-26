// run の最中の XCUITest ランナーの測り直し(RunOrchestrator の `recheckRunner` に渡す実体)。
// `fleetest run`(ProfileRunner)と `api run`(ApiRunCommand)の 2 経路が同じ関数を渡す
// (`RunnerMidRunRecheckTests`)。リモートの子は `fleetest run --runner local` なので前者を通る。

import FTBridgeClient
import FTCore
import Foundation

enum RunnerMidRunRecheck {
    /// 測り直す対象のレーンか。**素の xcuitest レーン(シミュレータ)だけ**:
    /// - hybrid / in-app は除く —— ランナーを建て直すと対象アプリごと落ち、同じ台の in-app ブリッジも
    ///   消える。供給時は直後の in-app の再利用がそれに気付いて建て直すが、run の途中には拾う者が居ない。
    ///   劣化の実測も xcuitest のレーンだけ(実測: 同じ台が in-app のフル E2E では 0 件)
    /// - 実機は除く —— 建て直しがデバイスのトランスポート越しで遅く、run 中の劣化の観測も無い
    static func target(of connection: DriverConnection) -> (udid: String, port: UInt16)? {
        guard connection.platform == "ios", !connection.physical,
              connection.engine == nil || connection.engine == "xcuitest",
              let udid = connection.udid,
              let port = connection.xcuiPort ?? connection.port else { return nil }
        return (udid, port)
    }

    /// 戻り値: 実際にブリッジを建て直したか(RunOrchestrator が WorkerAnomalyRecord
    /// kind:"recovered" recovery:.runnerRestart を記録する材料。健全・未測定・対象外・
    /// 建て直し失敗はいずれも false)
    static func recheck(worker: RunWorker, maxStepSnapshotMs: Int?, repoRoot: URL,
                        log: @escaping @Sendable (String) -> Void) async -> Bool {
        guard let target = target(of: worker.connection) else { return false }
        let injected = RunnerAccessibilityHealth.injectedSlowPorts().contains(target.port)
        guard RunnerAccessibilityHealth.shouldRecheck(maxStepSnapshotMs: maxStepSnapshotMs,
                                                      injected: injected) else { return false }
        let name = worker.connection.deviceName ?? worker.label
        let result = await BridgeProvisioner(repoRoot: repoRoot).recheckRunner(
            name: name, udid: target.udid, port: target.port, injected: injected, log: log)
        switch result.outcome {
        case .healthy, .unmeasured:
            log(RunnerAccessibilityHealth.leftRunningMessage(
                name: name, port: target.port, maxStepSnapshotMs: maxStepSnapshotMs,
                probeSeconds: result.probeSeconds))
            return false
        case .restarted(let afterSeconds):
            let now = afterSeconds.map { "; a one-element query now takes \(String(format: "%.2f", $0))s" } ?? ""
            log("✅ \(name): restarted the xcuitest bridge on port \(target.port)\(now) — the lane continues")
            return true
        case .restartDidNotHelp, .skipped:
            // 前者は restartRunner が 1 行出し済み・後者はその 1 行が既に出ている
            return false
        case .restartFailed(let reason):
            // レーンは離脱させない: ランナーが本当に使えなければ次のシナリオが落ち、
            // 既存の事後プローブ(bridgeUnreachable → 離脱 → revive)が拾う
            log("⚠️ \(name): could not restart the xcuitest bridge on port \(target.port) (\(reason))"
                + " — the lane continues as it is")
            return false
        }
    }
}
