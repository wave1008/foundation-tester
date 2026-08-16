// パフォーマンステストモード用の判定を1箇所に固定する。呼び手(Android/iOS の run 開始前ゲート)は
// ここへ転送するだけにすること(FleetOutcome.resolve と同じ規律)。

import Foundation

public enum LaneGate {
    /// プロファイルが要求したデバイス(expected)のうち、ワーカーとして立ち上がらなかった
    /// (actual に無い)ものの名前。expected の順序を保つ
    public static func missing(expected: [String], actual: [String]) -> [String] {
        let actualSet = Set(actual)
        return expected.filter { !actualSet.contains($0) }
    }
}
