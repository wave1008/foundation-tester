// 再利用する XCUITest ランナーが「AX 照会のたびに数秒待つ」状態に落ちていないかの判定(純粋関数)。
//
// 2026-09-14 実測(台帳 §19.27): 3 時間生きたランナーが、SpringBoard の remote element(DragUI の druid)を
// 引けなくなった後も参照し続け、**存在確認 1 回ごとに約 3.7 秒**(XCTest が remote element を諦める時間)
// 待つようになった。同じ木の照会が隣の台では 0.03〜0.27 秒。run のすべての XCUITest 照会に乗るので、
// 1 シナリオ 6 秒が 22 秒になり、in-app の tap も(前面確認で fallback を引くため)0.5 秒が 4 秒になる。
// ランナーを建て直すと直る(シミュレータの再起動は要らない)。druid を意図的に再起動しても再現しないため
// 発生条件は未特定 —— だから**再利用の入口で 1 問だけ測って、遅ければ建て直す**。
// **run の最中にも再発する**(2026-09-16: xcuitest の 4 プロファイルで毎回 供給時に検出 → 建て直し →
// run 中にまた 2 秒超のステップが 7/22・22/91 本)ので、緑のシナリオの直後にも同じ 1 問で測り直す
// (`BridgeProvisioner.recheckRunner` / fleetest の `RunnerMidRunRecheck`)。

import Foundation

/// 建て直しても直らなかった台(udid)。**このプロセスの間だけ**覚える(run ごとに作り直される)。
/// 2026-09-16 実測: -01 は建て直すたびに新しいランナーでも 1 問 2.9〜3.0 秒のまま(同時刻の他の台は
/// 0.03 秒)で、緑のシナリオのたびに約 10 秒の建て直しを空振りしていた。測って健全なら消す
/// (長く生きるプロセス = MCP で、シミュレータを再起動して直った台を覚え続けないため)
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

    /// 劣化 = 所要が閾値以上。測れなかった(nil)は劣化と言わない(不明を建て直しの根拠にしない)
    public static func isDegraded(probeSeconds: TimeInterval?) -> Bool {
        guard let probeSeconds else { return false }
        return probeSeconds >= slowProbeSeconds
    }

    /// 1 問の所要。答えなかった・旧ランナー(404)は nil(不明 = 劣化と言わない)。
    /// 供給時の再利用と run 中の測り直しが同じ関数を通る(測り方が割れると同じ台で判断が食い違う)
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

    /// 建て直した直後の新しいランナーでもまだ遅かったときの 1 行。**新しいプロセスでも遅い = 遅さは
    /// ランナーのプロセスには無い**(測った事実から言えるのはここまで)。以降このプロセスでは建て直さない。
    /// 次の手としてシミュレータの再起動を挙げる根拠: 2026-09-16 の -01 は建て直しでは 2.7〜3.0 秒のまま、
    /// 再起動で 0.03 秒に戻った(同じ 3 シナリオの合計 42.3s → 22.1s)
    public static func restartDidNotHelpMessage(name: String, port: UInt16, afterSeconds: TimeInterval) -> String {
        "⚠️ \(name): the restarted xcuitest bridge on port \(port) still took"
            + " \(String(format: "%.1f", afterSeconds))s for a one-element accessibility query"
            + " (normal is under 0.3s), so the slowness is not in the runner process"
            + " — it is not restarted again in this run; rebooting the simulator is the next thing to try"
    }

    /// 以前に建て直しても直らなかった台を、測り直さずにそのまま使うときの 1 行
    public static func keptSlowRunnerMessage(name: String, port: UInt16) -> String {
        "→ \(name): reusing the xcuitest bridge on port \(port) as it is"
            + " (restarting it did not help earlier in this process)"
    }

    /// run 中に測り直して建て直さなかったときの 1 行。**ステップが遅かった事実と測った結果だけを並べる**
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

    /// 建て直すときの 1 行(呼び手はそのまま log へ)
    public static func restartMessage(name: String, port: UInt16, probeSeconds: TimeInterval?, injected: Bool) -> String {
        let measured = injected ? "injected as slow (FT_FAKE_SLOW_RUNNER_PORTS)"
            : "answered a one-element accessibility query in \(String(format: "%.1f", probeSeconds ?? 0))s"
        return "⚠️ \(name): the xcuitest bridge on port \(port) \(measured); normal is under 0.3s"
            + " (a stale remote element after a system daemon restart makes every query wait"
            + " ~\(Int(slowProbeSeconds * 2))s) — restarting it"
    }
}
