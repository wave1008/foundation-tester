// WorkerCircuitBreaker.swift
// ワーカー・サーキットブレーカの判定(純粋ロジック。I/O 無し)。RunOrchestrator.runWorker が
// レーンごとに1つ持ち、通過/失敗を流し込む。
//
// 離脱の前提は「**このレーンだけ**が不調で、run は他で健全」。連続失敗の数だけで離脱させると、
// 外部依存(規約サイト・予約 API)が落ちて**全レーンが同時に失敗**する時間帯に、全部離脱 →
// 再投入 → 離脱 → revive 上限 → 残りが `no usable workers` で未実行のまま失敗、になる
// (受け手報告 2026-08-23: 39 本中 34 本失敗・多数が未実行)。
//
// そこで離脱には**証拠**を要求する: このレーンの連続失敗が始まってから、**別のレーンが1本でも
// 通った**ときだけ離脱する(通ったレーンがある = run は健全で、落ち続けているのはこの台)。
// 誰も通っていなければ台ではなく run 全体の問題なので、レーンを残して走り続ける(赤が並ぶ・
// 未実行は出ない)。凍結・消失・ブリッジ到達不能のプローブはこの判定の前段で別に効く。
//
// 却下した代替: condition 段階の失敗を数えない(不良な台は launch / 最初のステップ = condition で
// 落ちるので、守るべき形を見なくなる)/ 閾値のプロファイル化だけ(障害の時間帯は予測できないので
// 常時高く設定 = 保護を捨てる)。
//
// 「run 全体の通過数」は呼び手が渡す(このレーン自身の通過は streak をリセットするので、
// streak の間に増えた分は必ず他レーンのもの)。

public struct WorkerCircuitBreaker: Equatable, Sendable {

    public enum Verdict: Equatable, Sendable {
        /// 閾値未満。続ける
        case keep
        /// 閾値に達し、streak の間に他レーンが通った → 離脱
        case trip(consecutive: Int)
        /// 閾値に達したが、streak の間に誰も通っていない → 離脱しない(初回だけ `announce` が true。
        /// 同じ streak で毎回言わない)
        case held(consecutive: Int, announce: Bool)
    }

    public let threshold: Int
    public private(set) var consecutiveFailures = 0
    private var runPassesAtStreakStart = 0
    private var heldAnnounced = false

    public init(threshold: Int) {
        self.threshold = threshold
    }

    public mutating func recordPass() {
        consecutiveFailures = 0
        heldAnnounced = false
    }

    /// - runPasses: run 全体でこれまでに通ったシナリオ数(全レーン合計)
    public mutating func recordFailure(runPasses: Int) -> Verdict {
        if consecutiveFailures == 0 { runPassesAtStreakStart = runPasses }
        consecutiveFailures += 1
        guard consecutiveFailures >= threshold else { return .keep }
        if runPasses > runPassesAtStreakStart {
            return .trip(consecutive: consecutiveFailures)
        }
        let announce = !heldAnnounced
        heldAnnounced = true
        return .held(consecutive: consecutiveFailures, announce: announce)
    }
}
