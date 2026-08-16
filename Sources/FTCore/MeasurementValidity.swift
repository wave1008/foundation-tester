// パフォーマンス計測として使える run かどうかの判定を1箇所に固定する。
// 呼び手(ProfileRunner/ApiRunCommand の finish 直前)はここへ転送するだけにすること
// (LaneGate.swift / FleetOutcome.swift と同じ規律)。

import Foundation

public enum MeasurementValidity {
    /// 規則: **performanceMode かつ「実行中にレーン数が変わった」= 無効**。
    /// 既定モード(performanceMode=false)は元から縮退込みで完走させる方針なので判定しない。
    ///
    /// レーン数が変わった証跡は2つ(`RunSummary` の doc 参照):
    /// - degradedWorkers: 実行中に劣化・離脱したワーカー(復帰した場合も含む=一時的にでも
    ///   レーンが減っている)
    /// - blankExclusions: run 前の blank 判定で除外されたワーカー
    ///
    /// freezeRetries は含めない(結果の取り消し+振り直しであって、レーン数自体は変わっていない)。
    public static func verdict(
        performanceMode: Bool, degradedWorkers: [String], blankExclusions: [String]
    ) -> (invalid: Bool, reasons: [String]) {
        guard performanceMode else { return (false, []) }
        var reasons: [String] = []
        if !degradedWorkers.isEmpty {
            reasons.append("\(degradedWorkers.count) lane(s) degraded or dropped during the run")
        }
        if !blankExclusions.isEmpty {
            reasons.append("\(blankExclusions.count) lane(s) excluded before the run started (blank screen)")
        }
        return (!reasons.isEmpty, reasons)
    }
}
