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
    /// 起動し直した直後のランナーが 1 問にも答えなかったデバイス(`.noAnswer`)。**遅いだけのデバイス(udids)とは別**:
    /// 遅いだけなら使い続けられるが、答えないデバイスは復帰させても同じ供給で同じ事象を踏む(ワーカー復帰の門)
    private var unanswering: Set<String> = []

    public init() {}

    public func markUnanswering(udid: String) {
        lock.lock()
        defer { lock.unlock() }
        unanswering.insert(udid)
    }

    public func containsUnanswering(udid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return unanswering.contains(udid)
    }

    public func mark(udid: String) {
        lock.lock()
        defer { lock.unlock() }
        udids.insert(udid)
    }

    public func clear(udid: String) {
        lock.lock()
        defer { lock.unlock() }
        udids.remove(udid)
        unanswering.remove(udid)
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

    /// 1 問の結果。**答えなかった(`.noAnswer`)は測れなかった(`.unknown`)と別**: 要求を出して時限まで待っても
    /// 返事が無かったのは測った事実(最悪の劣化)で、404(旧ランナー)・接続拒否・即切れのような「測れなかった」ではない
    public enum ProbeOutcome: Equatable, Sendable {
        case answered(TimeInterval)
        /// 返事の無いまま `waited` 秒待った(= 少なくとも `slowProbeSeconds` 以上)
        case noAnswer(waited: TimeInterval)
        case unknown
    }

    /// 劣化 = 答えたが閾値以上 / 答えなかった。測れなかった(`.unknown`・nil)は劣化と言わない(不明を起動し直しの根拠にしない)
    public static func isDegraded(_ outcome: ProbeOutcome?) -> Bool {
        switch outcome {
        case .answered(let seconds): return seconds >= slowProbeSeconds
        case .noAnswer: return true
        case .unknown, nil: return false
        }
    }

    /// 失敗した 1 問を分類する(純粋関数)。**「届かなかった」型(`bridgeUnreachable` = 接続は張れたが返事が無い・時限切れ)を、
    /// 閾値以上待ったときだけ**答えなかったと言う。それより短く切れたもの(即 reset 等)は待った事実が無いので不明
    static func classifyFailure(unreachable: Bool, waited: TimeInterval) -> ProbeOutcome {
        unreachable && waited >= slowProbeSeconds ? .noAnswer(waited: waited) : .unknown
    }

    /// **起動し直し(ランナー・シミュレータ・初期化)の直後の 1 問で、直ったと言えるか**(純粋関数)。
    /// 答えて閾値未満のときだけ true。自分で起動した直後のランナーは旧ランナー(404)にも接続拒否にもなり得ないので、
    /// 答えなかった・測れなかったを「直った」に数えない(測れなかった回復を成功にすると、印が書かれず次の run が同じ空振りを繰り返す)
    public static func restartHelped(after: ProbeOutcome) -> Bool {
        if case .answered(let seconds) = after { return seconds < slowProbeSeconds }
        return false
    }

    /// 1 問の所要。供給時の再利用と run 中の測り直しが同じ関数を通る(測り方が割れると同じデバイスで判断が食い違う)
    public static func probe(port: UInt16, repoRoot: URL) async -> ProbeOutcome {
        let client = BridgeClient(endpoint: BridgeEndpoint.load(port: port, repoRoot: repoRoot))
        let started = Date()
        do {
            guard try await client.systemAlert() != nil else { return .unknown }  // 404 = 旧ランナー
            return .answered(Date().timeIntervalSince(started))
        } catch DriverError.bridgeUnreachable {
            return classifyFailure(unreachable: true, waited: Date().timeIntervalSince(started))
        } catch {
            return .unknown
        }
    }

    /// 結果を 1 句にする(ログ・注記が共有する。答えなかったは「N 秒以内に答えなかった」と言い、0.0s と書かない)
    public static func measuredPhrase(_ outcome: ProbeOutcome?) -> String {
        switch outcome {
        case .answered(let seconds):
            return "answered a one-element accessibility query in \(String(format: "%.1f", seconds))s"
        case .noAnswer(let waited):
            return "did not answer a one-element accessibility query within \(Int(waited.rounded()))s"
        case .unknown, nil:
            return "did not answer a one-element accessibility query (not measured)"
        }
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
    public static func restartDidNotHelpMessage(name: String, port: UInt16, after: ProbeOutcome) -> String {
        let tail = " — it is not restarted again in this run; rebooting the simulator is the next thing to try"
        let prefix = "⚠️ \(name): after restarting SpringBoard (on a simulator) and the xcuitest bridge on port \(port), it"
        switch after {
        case .answered(let seconds):
            return prefix + " still took \(String(format: "%.1f", seconds))s for a one-element accessibility query"
                + " (normal is under 0.3s)" + tail
        case .noAnswer(let waited):
            return prefix + " still did not answer a one-element accessibility query within \(Int(waited.rounded()))s"
                + " (normal is under 0.3s)" + tail
        case .unknown:
            return prefix + " could not be measured for a one-element accessibility query" + tail
        }
    }

    /// 以前に起動し直しても直らなかったデバイスを、測り直さずにそのまま使うときの 1 行
    public static func keptSlowRunnerMessage(name: String, port: UInt16) -> String {
        "→ \(name): reusing the xcuitest bridge on port \(port) as it is"
            + " (restarting it did not help earlier in this process)"
    }

    /// run 中に測り直して起動し直さなかったときの 1 行。**ステップが遅かった事実と測った結果だけを並べる**
    /// (遅さがどこから来たかはこれ以上言わない。SlowWorkerFinding.consoleWarning と同じ規律)
    public static func leftRunningMessage(name: String, port: UInt16, maxStepSnapshotMs: Int?,
                                          probe: ProbeOutcome?) -> String {
        let step = maxStepSnapshotMs.map { "a step spent \($0)ms taking snapshots; " } ?? ""
        let measured = measuredPhrase(probe)
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
    public static func liveDegradedNote(port: UInt16, probe: ProbeOutcome?, injected: Bool,
                                        autoStarts: Bool) -> String {
        let measured = injected ? "is injected as slow (FT_FAKE_SLOW_RUNNER_PORTS)" : measuredPhrase(probe)
        let restart = autoStarts
            ? "`fleetest bridge down --port \(port)` (live control starts it again on the next action)"
            : "`fleetest bridge down --port \(port)`, then start it again"
        return "the xcuitest bridge on port \(port) \(measured); normal is under 0.3s, and every"
            + " operation here pays that wait on each accessibility query (a stale remote element"
            + " after a system daemon restart). Restart the bridge first: \(restart);"
            + " if it is still this slow afterwards, reboot the simulator"
    }

    /// 起動し直すときの 1 行(呼び手はそのまま log へ)
    public static func restartMessage(name: String, port: UInt16, probe: ProbeOutcome?, injected: Bool) -> String {
        let measured = injected ? "injected as slow (FT_FAKE_SLOW_RUNNER_PORTS)" : measuredPhrase(probe)
        return "⚠️ \(name): the xcuitest bridge on port \(port) \(measured); normal is under 0.3s"
            + " (a stale remote element after a system daemon restart makes every query wait"
            + " ~\(Int(slowProbeSeconds * 2))s) — restarting it (SpringBoard first on a simulator)"
    }

    // MARK: - 印を run をまたいで持ち越す(RunnerSlownessStore)

    /// 供給の入口で、run をまたいだ印(`RunnerSlownessStore`)から次に何を試すかを決める(純粋関数)。
    /// **リースのあるデバイスには絶対に触らない**(ユーザー決定)—— 印があっても再起動・初期化を試みず、
    /// 「起動し直さずそのまま使う」に落とす。`canWipe` = `wipeBlock` が nil(初期化してよい状態)
    public enum SupplySlownessAction: Equatable, Sendable {
        /// 印なし。1 問プローブしてから必要なら起動し直す
        case proceedNormally
        /// 印 = runnerRestartDidNotHelp かつリース無し。シミュレータを再起動し、直らなければ(`canWipe` なら)同じ供給の中で初期化する
        case restartSimulator
        /// 印 = simulatorRestartDidNotHelp で、初期化してよい状態。再起動を省いて初期化する(再起動は試し済み)
        case wipeSimulator
        /// 印 = wipeDidNotHelp、リースがあるデバイス、または初期化できない状態の simulatorRestartDidNotHelp。何も撃たずそのまま使う
        case reuseWithoutRestarting
    }

    public static func supplySlownessAction(persisted: RunnerSlowness?, hasForeignLease: Bool,
                                            canWipe: Bool) -> SupplySlownessAction {
        switch persisted {
        case nil: return .proceedNormally
        case .wipeDidNotHelp: return .reuseWithoutRestarting
        case .simulatorRestartDidNotHelp:
            return !hasForeignLease && canWipe ? .wipeSimulator : .reuseWithoutRestarting
        case .runnerRestartDidNotHelp: return hasForeignLease ? .reuseWithoutRestarting : .restartSimulator
        }
    }

    /// 初期化(erase)してはいけない理由(純粋関数)。nil = してよい。**全部満たしたときだけ初期化する**:
    /// シミュレータであること(実機は消せない)・他のセッションが使っていないこと(消すと相手の run が落ちる)・
    /// この供給の後でアプリが入れ直されること(消えたアプリを戻す経路が無いと、run がアプリ無しで始まる)
    public enum WipeBlock: Equatable, Sendable {
        case physicalDevice
        case foreignLease
        case appNotReinstalled
    }

    public static func wipeBlock(isSimulator: Bool, hasForeignLease: Bool, runReinstallsApp: Bool) -> WipeBlock? {
        if !isSimulator { return .physicalDevice }
        if hasForeignLease { return .foreignLease }
        if !runReinstallsApp { return .appNotReinstalled }
        return nil
    }

    /// **ワーカーを復帰させてよいか**(純粋関数)。起動し直した直後のランナーが 1 問にも答えなかったデバイス
    /// (`RunnerRestartFutility.containsUnanswering`)は、復帰させても同じ供給で同じ事象を踏み、復帰のたびに数分を失う。
    /// 遅いだけのデバイス・udid の無いワーカー(Android 等)は対象外
    public static func shouldReviveWorker(udid: String?, futility: RunnerRestartFutility) -> Bool {
        guard let udid else { return true }
        return !futility.containsUnanswering(udid: udid)
    }

    /// 復帰させないときの 1 行(測った事実と、次の run で起きること)
    public static func reviveRefusedMessage(name: String) -> String {
        "⛔ not reviving \(name): restarting SpringBoard and the xcuitest bridge did not make it answer an"
            + " accessibility query earlier in this run. The next run reboots the simulator and, if that does"
            + " not help, erases it (only when no other session holds the device and the profile installs the app)"
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

    /// 測り直した結果を「…の 1 問に〜」の形にする(`measuredPhrase` と違い、文中の主語はブリッジ)
    private static func stillPhrase(_ after: ProbeOutcome?) -> String {
        switch after {
        case .answered(let seconds):
            return "still took \(String(format: "%.1f", seconds))s for a one-element accessibility query"
                + " (normal is under 0.3s)"
        case .noAnswer(let waited):
            return "still did not answer a one-element accessibility query within \(Int(waited.rounded()))s"
        case .unknown, nil:
            return "still could not be measured for a one-element accessibility query"
        }
    }

    /// シミュレータの再起動でも直らず、**初期化しない**ときの 1 行。**測った事実だけ**(帰属は書かない)。
    /// 呼び手が印を simulatorRestartDidNotHelp に更新する(初期化できる状態になった次の供給で初期化する)
    public static func simulatorRestartDidNotHelpMessage(name: String, port: UInt16, after: ProbeOutcome?) -> String {
        "⚠️ \(name): the xcuitest bridge on port \(port) \(stillPhrase(after)) after rebooting the simulator"
            + " — the simulator is not erased now; it is erased in the next supply that is allowed to"
    }

    /// 初期化する前の 1 行。`afterReboot` = 同じ供給の中で再起動した直後(false = 前の run の再起動で直らなかった印から来た)
    public static func erasingSimulatorMessage(name: String, port: UInt16, after: ProbeOutcome?,
                                               afterReboot: Bool) -> String {
        let cause = afterReboot
            ? "the xcuitest bridge on port \(port) \(stillPhrase(after)) after rebooting the simulator"
            : "rebooting the simulator did not make the xcuitest bridge on port \(port) healthy in an earlier run"
        return "⚠️ \(name): \(cause) — erasing the simulator (its apps and data are deleted;"
            + " the app under test is reinstalled by this run)"
    }

    /// 初期化しても直らなかったときの 1 行。以後は何も自動で撃たない(呼び手が印を wipeDidNotHelp に更新する)
    public static func wipeDidNotHelpMessage(name: String, port: UInt16, after: ProbeOutcome?) -> String {
        "⚠️ \(name): the xcuitest bridge on port \(port) \(stillPhrase(after)) after erasing the simulator"
            + " — nothing further is tried automatically for this device"
    }

    /// 初期化したいが条件を満たさないときの 1 行(してよい状態にするための手も添える)
    public static func wipeSkippedMessage(name: String, udid: String, block: WipeBlock) -> String {
        let reason: String
        switch block {
        case .physicalDevice:
            reason = "it is a physical device"
        case .foreignLease:
            reason = "another session is using this device"
        case .appNotReinstalled:
            reason = "this run does not reinstall the app under test (set autoInstall and appPath in the apps profile)"
        }
        return "→ \(name): not erasing the simulator because \(reason). To erase it by hand:"
            + " `fleetest api wipe-device --platform ios --udid \(udid)`"
    }

    /// 印 = wipeDidNotHelp のデバイスを、触らずそのまま使うときの 1 行
    public static func keptAfterWipeFailedMessage(name: String, port: UInt16) -> String {
        "→ \(name): reusing the xcuitest bridge on port \(port) as it is"
            + " (rebooting and erasing the simulator did not help, so nothing further is tried"
            + " automatically for this device)"
    }

    /// 印 = simulatorRestartDidNotHelp で、初期化してよい状態でないデバイスを、触らずそのまま使うときの 1 行
    public static func keptAfterSimulatorRestartFailedMessage(name: String, port: UInt16) -> String {
        "→ \(name): reusing the xcuitest bridge on port \(port) as it is"
            + " (rebooting the simulator did not help, and it is not erased in this supply)"
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
