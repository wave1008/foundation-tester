// 再利用する XCUITest ランナーが「AX 照会のたびに数秒待つ」状態に落ちていないかの判定(純粋関数)。
//
// 2026-09-14 実測(台帳 §19.27): 3 時間生きたランナーが、SpringBoard の remote element(DragUI の druid)を
// 引けなくなった後も参照し続け、**存在確認 1 回ごとに約 3.7 秒**(XCTest が remote element を諦める時間)
// 待つようになった。同じ木の照会が隣の台では 0.03〜0.27 秒。run のすべての XCUITest 照会に乗るので、
// 1 シナリオ 6 秒が 22 秒になり、in-app の tap も(前面確認で fallback を引くため)0.5 秒が 4 秒になる。
// ランナーを建て直すと直る(シミュレータの再起動は要らない)。druid を意図的に再起動しても再現しないため
// 発生条件は未特定 —— だから**再利用の入口で 1 問だけ測って、遅ければ建て直す**。

import Foundation

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
