// BridgeLogRotation.swift
// xcresult の保持容量が guarded(生きているブリッジ)だけで超過したとき、起動し直す価値がある
// (起動し直せば束が孤児になり、既存の孤児掃除 `BridgeLauncher.sweepOrphanResultBundles` が消す)
// 束を1つ選ぶ。I/O を持たない純粋関数——ポートの抽出・デバイスへの対応・実際の起動し直しは
// 呼び手(Sources/fleetest)の役割。
//
// 判定は既存の RetentionSweep.plan と RetentionPolicy.sweepLine をそのまま使う
// (`RetentionSweeper.clean` の notice と同じ条件にするため。別の閾値を作らない)。

import Foundation

public enum BridgeLogRotation {
    /// `sessions` の `overCapAfterGuards` が立っていなければ nil。立っていれば、guarded な
    /// Session のうち bytes 最大のもの(同点は id 昇順)を返す
    public static func candidate(
        sessions: [RetentionSweep.Session], maxBytes: Int64
    ) -> RetentionSweep.Session? {
        let line = RetentionPolicy.sweepLine(forCap: maxBytes)
        let plan = RetentionSweep.plan(sessions: sessions, maxBytes: line)
        guard plan.overCapAfterGuards else { return nil }
        return sessions.filter(\.guarded).sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id
        }.first
    }
}
