// ワーカーを1本ずつ参加させるときの「開始してよいか」の判定。
//
// 門は2つある(どちらも通ってから開始する):
//   ① **間隔**  —— 先頭 `simultaneousHead` 本は待たず、それ以降は `WorkerStagger.seconds` 待つ
//   ② **CPU**   —— 直近の CPU 使用率が上限(既定 100%)未満になるまで待つ。
//                  **こちらは先頭の同時起動枠も通る**(2026-08-09 ユーザー指示)——
//                  先頭免除は「間隔を空けない」という意味であって、飽和したホストへ
//                  1本目を撃ってよいという意味ではない。供給(install・ブリッジ注入)が
//                  重い run では、最初の launch の時点で既に詰まっている
//
// なぜ②が要るか(2026-08-09 ユーザー指示): 間隔は「1.5 秒あれば空くだろう」という
// **時間の当て推量**でしかなく、ホストが実際に空いたことは確かめていない。供給(install や
// ブリッジ注入)が長引いた run では、間隔を空けても飽和したまま次を起こしてしまう。
// 見るべきは経過時間ではなく**負荷そのもの**。
//
// **待ち続けない**: 上限まで空かなかったら**その run では②を諦めて素通しにする**
// (`gaveUpOnCPU`)。飽和の理由がテストと無関係(別のビルド等)のとき、10 本 × 上限ぶん
// 立ち上がりが延びると run 自体が使い物にならない。諦めたことは必ず1回ログに出す。
//
// 計測できない環境(host_processor_info が失敗)では②を**素通し**する —— 測れないことを
// 理由に run を止めない。

import Foundation

extension WorkerStagger {

    /// **これ未満なら開始してよい** CPU 使用率(1.0 = 全コア合計で 100%)。
    /// 既定が 100% ちょうどなのは「飽和していなければ開始」の意 —— 空くのを待つのではなく、
    /// **詰まっている間だけ止める**のが狙いで、余裕を要求すると立ち上がりが際限なく延びる
    public static let defaultCPUCeiling = 1.0

    /// 上限まで空かなければ諦めて素通しする(立ち上がりの延びをここで打ち切る)
    public static let cpuWaitCap = 30.0

    /// CPU を見に行く間隔。**この間隔がそのまま計測窓**になる(CPUSampler は前回サンプルからの
    /// デルタを返すため)。短すぎると瞬間値を拾って揺れる
    public static let cpuPollInterval = 0.5

    /// `FT_WORKER_START_CPU_MAX` で差し替え可能(対照実験用)。
    /// **`1` 以下は割合・超えるならパーセント**として読む(`0.85` も `85` も 85%)。
    /// 不正値は既定へ倒す(黙って 0 にすると門を外した run になる)
    public static var cpuCeiling: Double {
        guard let raw = ProcessInfo.processInfo.environment["FT_WORKER_START_CPU_MAX"] else {
            return defaultCPUCeiling
        }
        guard let value = Double(raw), value.isFinite, value > 0 else { return defaultCPUCeiling }
        let fraction = value <= 1.0 ? value : value / 100.0
        guard fraction > 0, fraction <= 1.0 else { return defaultCPUCeiling }
        return fraction
    }
}

/// 実時間・実サンプラを注入して使う(テストは時計を進めずに全分岐を通す)。
/// **Sendable ではない** —— 起動ループ(RunOrchestrator の admit)の中だけで使い、
/// 別タスクへ渡さない前提。CPUSampler が可変状態を持つため。
public final class WorkerStartGate {

    /// 1本ぶんの判定結果(テストとログのため)
    public enum Outcome: Equatable {
        /// 間隔だけ待って開始(CPU は上限未満だった、または計測不能・門が無効)。
        /// **先頭の同時起動枠は `waited: 0`** —— 「待たずに開始」を別の case にすると
        /// 「CPU を見たか」が読めなくなる
        case interval(waited: Double)
        /// CPU が空くのを待って開始(合計の待ち時間と、開始時に見えた負荷)
        case waitedForCPU(waited: Double, load: Double)
        /// 上限まで待っても空かなかったので開始し、以降は CPU の門を使わない
        case gaveUpOnCPU(lastLoad: Double?)
    }

    private let intervalSeconds: Double
    private let simultaneousHead: Int
    private let ceiling: Double
    private let cap: Double
    private let pollInterval: Double
    private let sampleCPU: () -> Double?
    private let sleep: (Double) async -> Void

    private var started = 0
    /// 一度諦めたら以降は CPU を見ない(立ち上がりの延びを上限1回ぶんに抑える)
    private var cpuGateAbandoned = false

    /// 最後に取れた使用率と、それを取ってからここで眠った秒数。
    ///
    /// **CPUSampler は連続で呼ぶと必ず nil を返す**(tick の差分が 0。実測で確認)。
    /// 素朴に「nil なら 1 窓眠って測り直す」だけにすると、**先頭2本が測定窓のぶん離れて
    /// しまい「間隔0」が崩れる**。1本目が測った値は2本目にとっても「直近の負荷」なので、
    /// **1 窓ぶんだけ**使い回す(それより古ければ捨てて測り直す)
    private var lastLoad: Double?
    private var sinceLastLoad = 0.0

    private(set) public var outcomes: [Outcome] = []

    public init(intervalSeconds: Double = WorkerStagger.seconds,
                simultaneousHead: Int = WorkerStagger.simultaneousHead,
                ceiling: Double = WorkerStagger.cpuCeiling,
                cap: Double = WorkerStagger.cpuWaitCap,
                pollInterval: Double = WorkerStagger.cpuPollInterval,
                sampleCPU: @escaping () -> Double?,
                sleep: @escaping (Double) async -> Void) {
        self.intervalSeconds = intervalSeconds
        self.simultaneousHead = simultaneousHead
        self.ceiling = ceiling
        self.cap = cap
        self.pollInterval = pollInterval
        self.sampleCPU = sampleCPU
        self.sleep = sleep
    }

    /// 次の1本を開始してよくなるまで待つ。呼ぶたびに「何本目か」が進む
    @discardableResult
    public func waitForTurn(log: (String) -> Void = { _ in }) async -> Outcome {
        defer { started += 1 }
        var waited = 0.0
        // **間隔だけ**が先頭免除。CPU の門はこの下で全員が通る
        if started >= simultaneousHead, intervalSeconds > 0 {
            await sleep(intervalSeconds)
            waited += intervalSeconds
            sinceLastLoad += intervalSeconds
        }
        let outcome = await waitForCPU(alreadyWaited: waited, log: log)
        outcomes.append(outcome)
        return outcome
    }

    /// 直近の CPU 使用率が上限未満になるまで待つ。
    /// **上限との比較は `<`** —— 「100% 未満なら開始」がそのまま既定になる
    private func waitForCPU(alreadyWaited: Double, log: (String) -> Void) async -> Outcome {
        guard !cpuGateAbandoned else { return .interval(waited: alreadyWaited) }
        var waited = alreadyWaited
        var cpuWaited = 0.0
        // 2回続けて取れなければ「測れない環境」と見なして素通しする。1回で諦めないのは、
        // CPUSampler が**呼び出し間隔が短いと必ず nil**(差分が取れない)ため
        var unavailable = 0
        while true {
            if let load = currentLoad() {
                unavailable = 0
                if load < ceiling {
                    return cpuWaited > 0
                        ? .waitedForCPU(waited: waited, load: load)
                        : .interval(waited: waited)
                }
            } else {
                unavailable += 1
                if unavailable >= 2 { return .interval(waited: waited) }
            }
            guard cpuWaited < cap else {
                cpuGateAbandoned = true
                log("⚠️ the host stayed at \(Self.percent(lastLoad)) CPU for \(Int(cap))s —"
                    + " starting the remaining workers without waiting for it to settle")
                return .gaveUpOnCPU(lastLoad: lastLoad)
            }
            await sleep(pollInterval)
            waited += pollInterval
            cpuWaited += pollInterval
            sinceLastLoad += pollInterval
        }
    }

    /// 今の使用率。取れなければ**1 窓以内に測った値**で代用する(それも無ければ nil)
    private func currentLoad() -> Double? {
        if let fresh = sampleCPU() {
            lastLoad = fresh
            sinceLastLoad = 0
            return fresh
        }
        guard let lastLoad, sinceLastLoad <= pollInterval else { return nil }
        return lastLoad
    }

    static func percent(_ load: Double?) -> String {
        guard let load else { return "an unknown" }
        return "\(Int((load * 100).rounded()))%"
    }
}
