// 再利用する XCUITest ランナーが「AX 照会のたびに数秒待つ」状態に落ちていないかの判定(純粋関数)。
//
// 実測(台帳 §19.27): 3 時間生きたランナーが、SpringBoard の remote element(DragUI の druid)を
// 引けなくなった後も参照し続け、**存在確認 1 回ごとに約 3.7 秒**(XCTest が remote element を諦める時間)
// 待つようになった。同じ木の照会が隣のデバイスでは 0.03〜0.27 秒。run のすべての XCUITest 照会に乗るので、
// 1 シナリオ 6 秒が 22 秒になり、in-app の tap も(前面確認で fallback を引くため)0.5 秒が 4 秒になる。
// ランナーを起動し直すと直る(シミュレータの再起動は要らない)。druid を意図的に再起動しても再現しないため
// 発生条件は未特定 —— だから**再利用の入口で 1 問だけ測って、遅ければ起動し直す**。
// **run の最中にも再発する**(xcuitest の 4 プロファイルで毎回 供給時に検出 → 起動し直し →
// run 中にまた 2 秒超のステップが 7/22・22/91 本)ので、緑のシナリオの直後にも同じ 1 問で測り直す
// (`BridgeProvisioner.recheckRunner` / fleetest の `RunnerMidRunRecheck`)。

import FTCore
import Foundation

/// 起動し直しても直らなかったデバイス(udid)。**このプロセスの間だけ**覚える(run ごとに作り直される)。
/// 実測: -01 は起動し直すたびに新しいランナーでも 1 問 2.9〜3.0 秒のまま(同時刻の他のデバイスは
/// 0.03 秒)で、緑のシナリオのたびに約 10 秒の起動し直しを空振りしていた。測って健全なら消す
/// (長く生きるプロセス = MCP で、シミュレータを再起動して直ったデバイスを覚え続けないため)
public final class RunnerRestartFutility: @unchecked Sendable {
    public static let shared = RunnerRestartFutility()
    private let lock = NSLock()
    private var udids: Set<String> = []

    public init() {}

    public func mark(udid: String) {
        lock.lock()
        defer { lock.unlock() }
        udids.insert(udid)
    }

    public func clear(udid: String) {
        lock.lock()
        defer { lock.unlock() }
        udids.remove(udid)
    }

    public func contains(udid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return udids.contains(udid)
    }
}

public enum RunnerAccessibilityHealth {
    /// `GET /systemalert`(SpringBoard の alerts.firstMatch.exists = 1 問)の所要がこれ以上なら劣化。
    /// **根拠**: 正常 0.03〜0.27 秒 / 劣化 3.7〜4.1 秒(XCTest の remote element タイムアウト)。
    /// 2 秒はその間で、機械が遅いだけの正常値(0.3 秒の数倍)には当たらない
    public static let slowProbeSeconds: TimeInterval = 2

    /// 劣化 = 所要が閾値以上。測れなかった(nil)は劣化と言わない(不明を起動し直しの根拠にしない)
    public static func isDegraded(probeSeconds: TimeInterval?) -> Bool {
        guard let probeSeconds else { return false }
        return probeSeconds >= slowProbeSeconds
    }

    /// 1 問の所要。答えなかった・旧ランナー(404)は nil(不明 = 劣化と言わない)。
    /// 供給時の再利用と run 中の測り直しが同じ関数を通る(測り方が割れると同じデバイスで判断が食い違う)
    public static func probe(port: UInt16, repoRoot: URL) async -> TimeInterval? {
        let client = BridgeClient(endpoint: BridgeEndpoint.load(port: port, repoRoot: repoRoot))
        let started = Date()
        guard (try? await client.systemAlert()) != nil else { return nil }
        return Date().timeIntervalSince(started)
    }

    /// **run の最中に測り直すかの門**(緑で終わったシナリオの直後に呼ぶ)。材料はそのシナリオの
    /// ステップごとの snapshot 所要の最大(ms)。**ステップの値は 1 ステップ内の照会の合計**なので
    /// 1 問の所要とは限らない —— これは「測るか」の門で、劣化の判定は測った 1 問(`isDegraded`)だけが行う。
    /// 門の値が劣化の閾値と同じなのは、劣化したランナーでは 1 問が 3.7 秒かかり、それを含むステップは
    /// 必ずこれを越えるため(越えないステップしか無い run では測らない = 健全な run は 1 問も払わない)。
    /// 材料が無い(nil)は測らない。注入されたポートは常に測る(陽性対照)
    public static func shouldRecheck(maxStepSnapshotMs: Int?, injected: Bool) -> Bool {
        if injected { return true }
        guard let maxStepSnapshotMs else { return false }
        return Double(maxStepSnapshotMs) >= slowProbeSeconds * 1000
    }

    /// 起動し直した直後の新しいランナーでもまだ遅かったときの 1 行。**新しいプロセスでも遅い = 遅さは
    /// ランナーのプロセスには無い**(測った事実から言えるのはここまで)。以降このプロセスでは起動し直さない。
    /// 次の手としてシミュレータの再起動を挙げる根拠: -01 は起動し直しでは 2.7〜3.0 秒のまま、
    /// 再起動で 0.03 秒に戻った(同じ 3 シナリオの合計 42.3s → 22.1s)
    public static func restartDidNotHelpMessage(name: String, port: UInt16, afterSeconds: TimeInterval) -> String {
        "⚠️ \(name): the restarted xcuitest bridge on port \(port) still took"
            + " \(String(format: "%.1f", afterSeconds))s for a one-element accessibility query"
            + " (normal is under 0.3s), so the slowness is not in the runner process"
            + " — it is not restarted again in this run; rebooting the simulator is the next thing to try"
    }

    /// 以前に起動し直しても直らなかったデバイスを、測り直さずにそのまま使うときの 1 行
    public static func keptSlowRunnerMessage(name: String, port: UInt16) -> String {
        "→ \(name): reusing the xcuitest bridge on port \(port) as it is"
            + " (restarting it did not help earlier in this process)"
    }

    /// run 中に測り直して起動し直さなかったときの 1 行。**ステップが遅かった事実と測った結果だけを並べる**
    /// (遅さがどこから来たかはこれ以上言わない。SlowWorkerFinding.consoleWarning と同じ規律)
    public static func leftRunningMessage(name: String, port: UInt16, maxStepSnapshotMs: Int?,
                                          probeSeconds: TimeInterval?) -> String {
        let step = maxStepSnapshotMs.map { "a step spent \($0)ms taking snapshots; " } ?? ""
        let measured = probeSeconds.map {
            "answered a one-element accessibility query in \(String(format: "%.1f", $0))s"
        } ?? "did not answer a one-element accessibility query (not measured)"
        return "→ \(name): \(step)the xcuitest bridge on port \(port) \(measured) — left running"
    }

    /// 注入口 `FT_FAKE_SLOW_RUNNER_PORTS=8123,8125`: そのポートの再利用を劣化とみなす
    /// (実際の劣化は意図的に起こせないので、配線の陽性対照はこれで撃つ。FT_FAKE_FROZEN_KEYS と同じ規律)
    public static func injectedSlowPorts(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Set<UInt16> {
        guard let raw = environment["FT_FAKE_SLOW_RUNNER_PORTS"] else { return [] }
        return Set(raw.split(separator: ",").compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// ライブ操作(`api live serve`)で、遅かった操作の直後に 1 問測って劣化していたときの注記
    /// (観測イベントの notes と stderr へ同じ文)。**ライブ操作は起動し直さず知らせるだけ**
    /// —— 人が操作している最中に数十秒の起動し直しを割り込ませない(新しい検知は警告から)。
    /// `autoStarts` = この serve が udid を持ち、止めたブリッジを次の操作で自動起動できる
    public static func liveDegradedNote(port: UInt16, probeSeconds: TimeInterval?, injected: Bool,
                                        autoStarts: Bool) -> String {
        let measured = injected ? "is injected as slow (FT_FAKE_SLOW_RUNNER_PORTS)"
            : "answered a one-element accessibility query in \(String(format: "%.1f", probeSeconds ?? 0))s"
        let restart = autoStarts
            ? "`fleetest bridge down --port \(port)` (live control starts it again on the next action)"
            : "`fleetest bridge down --port \(port)`, then start it again"
        return "the xcuitest bridge on port \(port) \(measured); normal is under 0.3s, and every"
            + " operation here pays that wait on each accessibility query (a stale remote element"
            + " after a system daemon restart). Restart the bridge first: \(restart);"
            + " if it is still this slow afterwards, reboot the simulator"
    }

    /// 起動し直すときの 1 行(呼び手はそのまま log へ)
    public static func restartMessage(name: String, port: UInt16, probeSeconds: TimeInterval?, injected: Bool) -> String {
        let measured = injected ? "injected as slow (FT_FAKE_SLOW_RUNNER_PORTS)"
            : "answered a one-element accessibility query in \(String(format: "%.1f", probeSeconds ?? 0))s"
        return "⚠️ \(name): the xcuitest bridge on port \(port) \(measured); normal is under 0.3s"
            + " (a stale remote element after a system daemon restart makes every query wait"
            + " ~\(Int(slowProbeSeconds * 2))s) — restarting it"
    }

    // MARK: - 印を run をまたいで持ち越す(RunnerSlownessStore)

    /// 供給の入口で、run をまたいだ印(`RunnerSlownessStore`)から次に何を試すかを決める(純粋関数)。
    /// **リースのあるデバイスには絶対に触らない**(ユーザー決定)—— 印があっても再起動を試みず、
    /// 「起動し直さずそのまま使う」に落とす
    public enum SupplySlownessAction: Equatable, Sendable {
        /// 印なし。1 問プローブしてから必要なら起動し直す
        case proceedNormally
        /// 印 = runnerRestartDidNotHelp かつリース無し。ブリッジを起動する前にシミュレータごと再起動する
        case restartSimulator
        /// 印 = simulatorRestartDidNotHelp、またはリースがあるデバイス。何も撃たずそのまま使う
        case reuseWithoutRestarting
    }

    public static func supplySlownessAction(persisted: RunnerSlowness?, hasForeignLease: Bool) -> SupplySlownessAction {
        switch persisted {
        case nil: return .proceedNormally
        case .simulatorRestartDidNotHelp: return .reuseWithoutRestarting
        case .runnerRestartDidNotHelp: return hasForeignLease ? .reuseWithoutRestarting : .restartSimulator
        }
    }

    /// run-lease / MCP の印のどちらかを**他プロセス**が持っているか(純粋関数)。自分自身が持つ
    /// run-lease は「使用中」に数えない(この run 自身が供給の中で自分のデバイスに触るのは正常)。
    /// `DeviceBooter.deviceInUseRefusal`(docs/remote-runner.md §18.7 規律④)と同じ規律だが、
    /// FTAndroid → FTBridgeClient の依存方向のためあちらを直接呼べない(循環)。RunLease/MCPDeviceLease は
    /// 同じモジュール(FTBridgeClient)に居るので、判定だけをここへ複製する
    static func hasForeignLease(runLeaseHolder: Int32?, mcpLeaseHolder: Int32?, selfPID: Int32) -> Bool {
        if let runLeaseHolder, runLeaseHolder != selfPID { return true }
        return mcpLeaseHolder != nil
    }

    /// I/O 版。selfPID/parentPID は既定値(本番はこのまま呼ぶ)。MCP の印は自分と親の分を数えない
    /// (`DeviceBooter.mcpLeaseHolderPID` と同じ理由: MCP が起こしたコマンドが自分のデバイスを
    /// 「他人が使用中」と誤読しない)
    public static func hasForeignLease(udid: String, stateDir: URL,
                                selfPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                                parentPID: Int32 = getppid()) -> Bool {
        hasForeignLease(
            runLeaseHolder: RunLease.holderPID(stateDir: stateDir, key: udid),
            mcpLeaseHolder: MCPDeviceLease.holderPID(stateDir: stateDir, key: udid,
                                                     excluding: [selfPID, parentPID]),
            selfPID: selfPID)
    }

    /// **呼び手がそのデバイスを持つ run なら他人と数えない**版(ブリッジを立て直す・起動し直す自動の経路用)。
    /// - run-lease の書き手が自分か親(run の子 = ScenarioHost が直接起こすシナリオ実行のプロセス)なら false。
    ///   **MCP の印があっても false** —— run は台が足りないと MCP の触っているデバイスを引き取る設計で
    ///   (引き取りの警告は MCP 側に出る)、引き取った run がブリッジを立て直せないとレーンが落ちる
    /// - それ以外は上の純粋関数のまま(止める門との一致は `LeaseJudgementAgreementTests`)。止める門・供給の
    ///   シミュレータ再起動は従来どおり「印があれば run でも触らない」で、この版を使わない
    public static func hasForeignLeaseUnlessOwnRun(
        key: String, stateDir: URL,
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier, parentPID: Int32 = getppid()
    ) -> Bool {
        let runHolder = RunLease.holderPID(stateDir: stateDir, key: key)
        if let runHolder, runHolder == selfPID || runHolder == parentPID { return false }
        return hasForeignLease(
            runLeaseHolder: runHolder,
            mcpLeaseHolder: MCPDeviceLease.holderPID(stateDir: stateDir, key: key,
                                                     excluding: [selfPID, parentPID]),
            selfPID: selfPID)
    }

    /// 他のセッションが使っているので起動し直さない・作り直さない、の1行(自動起動・自動回復の門が共有する)
    public static func deviceHeldByAnotherSessionMessage(device: String, what: String) -> String {
        "not \(what) for \(device): another session (a fleetest run or an MCP session) is using this device,"
            + " and doing so would take its bridge down. Wait for that session to finish, or drive another device"
    }

    /// シミュレータごと再起動する前の 1 行。「前の run で」と言えるのは、この印が
    /// `RunnerSlownessStore` でプロセスを跨いで残るため(`RunnerRestartFutility` はプロセス内だけ)
    public static func restartingSimulatorMessage(name: String, port: UInt16) -> String {
        "⚠️ \(name): the xcuitest bridge on port \(port) was still slow after a runner restart"
            + " in an earlier run — rebooting the simulator before reusing it"
    }

    /// シミュレータの再起動でも直らなかったときの 1 行。**測った事実だけ**を言う(帰属は書かない)。
    /// 以後このデバイスには何も自動で撃たない(呼び手が印を simulatorRestartDidNotHelp に更新する)
    public static func simulatorRestartDidNotHelpMessage(name: String, port: UInt16,
                                                          afterSeconds: TimeInterval?) -> String {
        let measured = afterSeconds.map { "\(String(format: "%.1f", $0))s" } ?? "an unmeasured amount of time"
        return "⚠️ \(name): the xcuitest bridge on port \(port) still took \(measured) for a"
            + " one-element accessibility query after rebooting the simulator (normal is under 0.3s)"
            + " — nothing further is tried automatically for this device"
    }

    /// 印 = simulatorRestartDidNotHelp のデバイスを、触らずそのまま使うときの 1 行
    public static func keptAfterSimulatorRestartFailedMessage(name: String, port: UInt16) -> String {
        "→ \(name): reusing the xcuitest bridge on port \(port) as it is"
            + " (rebooting the simulator did not help either, so nothing further is tried"
            + " automatically for this device)"
    }

    /// 今遅かったが、このデバイスを他のセッション(run または MCP)が使用中なので起動し直さないときの 1 行
    public static func keptBecauseLeasedNowMessage(name: String, port: UInt16) -> String {
        "→ \(name): reusing the xcuitest bridge on port \(port) as it is"
            + " (it answered slowly, but another session is using this device right now, so it is not restarted)"
    }

    /// 印はあるが、このデバイスを今どこかのセッション(run または MCP)が使用中なので触らないときの 1 行
    public static func keptBecauseLeasedMessage(name: String, port: UInt16) -> String {
        "→ \(name): reusing the xcuitest bridge on port \(port) as it is"
            + " (it was slow in an earlier run, but another session is using this device right now,"
            + " so it is not touched)"
    }
}
