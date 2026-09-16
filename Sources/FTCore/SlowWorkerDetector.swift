// SlowWorkerDetector.swift
// 「台そのものが遅い」ことの**観測だけ**を行う純粋関数(自動修復・除外はしない)。
// 根拠(2026-09-15 の3時間負荷テスト): シミュレータ1台だけが3 run連続で in-app snapshot
// 4.3〜4.4秒に張り付いた(通常は数十ms。他7台は15ラウンドで2秒超が3回以下)。ホストCPUでは
// 説明が付かず(中央値56%・前後のラウンドと同等)、XCUITestランナーを建て直しても直らなかった。
// **これはその1件の帰属であって、この検知が導けることではない**(consoleWarning の宣言参照)。
// 4.4秒はステップtimeout(`FTCore.DefaultWait.seconds`=5秒)未満
// なので既存の `slow-snapshot` 注記(timeout超過)は立たず、所要以外に痕跡が残らない。
//
// 2026-09-16 の負荷テストで2つ目の形が見つかった: **中央値は正常なのに一部の照会だけ遅い**台
// (中央値8ms・p90 3579ms・2秒超が43%)は上の中央値判定に1度も引っかからない。中央値側は
// 変えず(両者の思想が違う: 中央値は「台が恒常的に遅い」、間欠側は「台がときどき詰まる」)、
// 2つ目の判定を追加する。実測(M1Max -04、4 run連続でホストの壁時計を決めていた台):
//   ios-inapp     46標本 中央値8ms   p90 3579ms 他レーン中央値6ms   2秒超43% 他レーン2秒超0%
//   ios-xcuitest  40標本 中央値293ms p90 3741ms 他レーン中央値68ms  2秒超40% 他レーン2秒超0%
//   ios-xcuitest  91標本 中央値167ms p90 3437ms 他レーン中央値62ms  2秒超26% 他レーン2秒超0%
// 健全な run(9/16 11:46 の全緑フル E2E・127レーン)との分離: 2秒超の割合の最大は
// 22標本中2本(9%)・p90の最大は1562ms。負荷テスト中の健全なレーンでも2秒超は最大22%だが
// 標本9本中2本(=5本未満)だった。
//
// 入力は ScenarioRunRecord.timeline の snapshotMs(worker ごとに束ねる)。他の欄
// (actionMs/waitMs 等)は対象にしない —— 実測の劣化は snapshot だけに出ていたため。

import Foundation

/// 1台の遅さの観測結果。除外・修復の判断材料ではなく事実(標本数・所要の分布)だけを持つ。
public struct SlowWorkerFinding: Sendable, Equatable {
    /// どちらの判定で立ったか。判定ごとに文言(summary/consoleWarning)を分ける
    public enum Kind: Sendable, Equatable {
        /// 台そのものが恒常的に遅い(中央値が他レーン全体の中央値の `relativeFactor` 倍以上)
        case median(medianMs: Int, fleetMedianMs: Int)
        /// 台が間欠的に詰まる(中央値は正常域でも、一部の照会だけ `intermittentFloorMs` 以上)
        case intermittent(slowSamples: Int, p90Ms: Int, fleetSlowSamples: Int, fleetSamples: Int)
    }

    /// ScenarioRunRecord.worker と同じ文字列("<platform>:<デバイス論理名>")
    public let worker: String
    public let samples: Int
    public let kind: Kind

    public init(worker: String, samples: Int, kind: Kind) {
        self.worker = worker
        self.samples = samples
        self.kind = kind
    }

    /// run.json `slowWorkers` 用の表示1行(degradedWorkers と同じ「事実だけの1行」規律)
    public var summary: String {
        switch kind {
        case let .median(medianMs, fleetMedianMs):
            return "\(worker): median snapshot \(medianMs)ms over \(samples) samples (other lanes \(fleetMedianMs)ms)"
        case let .intermittent(slowSamples, p90Ms, fleetSlowSamples, fleetSamples):
            return "\(worker): \(slowSamples) of \(samples) snapshots took \(SlowWorkerDetector.intermittentFloorMs)ms+"
                + " (p90 \(p90Ms)ms, other lanes \(fleetSlowSamples) of \(fleetSamples))"
        }
    }

    /// CLI 末尾の警告1行(英語)。**FrozenVerdict とは別の観測であること**と
    /// **自動では何もしないこと**を含める(受け手が誤って「ツールが直した」と読まないため)。
    /// **遅さの帰属(台かランナーか)は書かない** —— 入力はワーカーごとの snapshotMs だけで
    /// 区別が付かない。2026-09-16 に実際に逆を書いていた: 同じ台が in-app のフル E2E では
    /// 1 度も鳴らず xcuitest でだけ鳴り、**同じ run の供給時プローブは「ランナーの stale remote
    /// element」と名指しして建て直していた**(`RunnerAccessibilityHealth`)ので、
    /// 2 つの検知が同じ台について正反対の帰属を出した
    public var consoleWarning: String {
        switch kind {
        case let .median(medianMs, fleetMedianMs):
            return "⚠️ slow lane: \(worker) answered snapshots in \(medianMs)ms (median of \(samples))"
                + " while other lanes took \(fleetMedianMs)ms"
                + " — an observation only; nothing was excluded or restarted because of it"
        case let .intermittent(slowSamples, p90Ms, fleetSlowSamples, fleetSamples):
            return "⚠️ intermittent slow lane: \(worker) had \(slowSamples) of \(samples) snapshots take"
                + " \(SlowWorkerDetector.intermittentFloorMs)ms+ (p90 \(p90Ms)ms) while other lanes had"
                + " \(fleetSlowSamples) of \(fleetSamples)"
                + " — an observation only; nothing was excluded or restarted because of it"
        }
    }
}

public enum SlowWorkerDetector {
    /// 判定に要る最小標本数。1シナリオの短い台本で偶然の1枚に引っ張られないための下限。
    /// 根拠: 実測の劣化は41ステップ中18回・67ステップ中23回で標本は十分にあった
    public static let minSamples = 8

    /// 「遅い」と言うための相対条件(他ワーカー全体の中央値の何倍か)。相対条件だけだと
    /// 全台が同じ速さで遅いrun(ホスト負荷)を1台のせいにしてしまうので absoluteFloorMs と併用する。
    /// 間欠判定でも同じ思想で「他レーン全体の遅い照会の割合」の相対上限として再利用する
    public static let relativeFactor = 10

    /// 「遅い」と言うための絶対条件(ms)。通常のin-app snapshot(数十ms)の1桁上、かつ
    /// ステップtimeout(`FTCore.DefaultWait.seconds`=5秒)の1/5 —— 既存の`slow-snapshot`注記
    /// (timeout超過でしか立たない)が原理的に見えない帯をここで拾う。絶対条件が無いと
    /// 元から遅い環境(実機USB等)で毎回鳴ってしまう
    public static let absoluteFloorMs = 1000

    /// 間欠的な劣化と言うための「遅い1照会」の下限(ms)。根拠(2026-09-16 負荷テスト):
    /// 劣化台の遅い照会は3.4〜4.0秒に張り付き、健全なレーンのp90は負荷下でも最大1562msだった。
    /// ステップtimeout(5秒)未満に置く —— それ以上は既に別の観測(slow-snapshot注記/timeout失敗)が
    /// 付くので、この判定が拾うべきなのはその手前の「timeoutには当たらないが遅い」帯
    public static let intermittentFloorMs = 2000

    /// 間欠的な劣化と言うための「遅い照会」の最小本数。根拠: 健全なレーンでも稀に2秒超が
    /// 出るが最大22標本中2本だった。5本以上なら偶発的な1〜2回の遅延と区別できる
    public static let intermittentMinSlowSamples = 5

    /// 間欠的な劣化と言うための「遅い照会」の割合の下限。根拠: 劣化台は26〜43%だったのに対し、
    /// 健全なレーンは負荷下(22標本中2本)でも最大9%だった
    public static let intermittentShare = 0.20

    /// timeline/snapshotMs を持たない要素は無視する。他ワーカーが居ない(1台のrun)、または
    /// 比較相手の標本が無いときは相対比較ができないため判定しない
    public static func detect(records: [ScenarioRunRecord]) -> [SlowWorkerFinding] {
        var byWorker: [String: [Int]] = [:]
        for record in records {
            guard let worker = record.worker, let timeline = record.timeline else { continue }
            for step in timeline {
                guard let snapshotMs = step.snapshotMs else { continue }
                byWorker[worker, default: []].append(snapshotMs)
            }
        }

        var findings: [SlowWorkerFinding] = []
        for (worker, samples) in byWorker.sorted(by: { $0.key < $1.key }) {
            guard samples.count >= minSamples else { continue }
            let others = byWorker.filter { $0.key != worker }.flatMap(\.value)
            guard !others.isEmpty else { continue }

            let workerMedian = median(samples)
            let fleetMedian = median(others)
            if workerMedian >= absoluteFloorMs, workerMedian >= fleetMedian * relativeFactor {
                // 中央値判定が立ったら間欠判定は見ない(1台につき1件にまとめる。中央値のほうが
                // 恒常的な劣化として既に事実を言い尽くしており、両方出すと同じ台が二重に出る)
                findings.append(SlowWorkerFinding(worker: worker, samples: samples.count,
                                                  kind: .median(medianMs: workerMedian, fleetMedianMs: fleetMedian)))
                continue
            }

            if let intermittent = intermittentFinding(worker: worker, samples: samples, others: others) {
                findings.append(intermittent)
            }
        }
        return findings
    }

    private static func intermittentFinding(worker: String, samples: [Int], others: [Int]) -> SlowWorkerFinding? {
        let slowSamples = samples.filter { $0 >= intermittentFloorMs }.count
        guard slowSamples >= intermittentMinSlowSamples else { return nil }

        let laneShare = Double(slowSamples) / Double(samples.count)
        guard laneShare >= intermittentShare else { return nil }

        // ホスト全体が遅い run(全レーンが同程度に2秒超)を1台のせいにしない。
        // 既存の中央値判定(relativeFactor倍)と同じ思想の相対条件
        let fleetSlowSamples = others.filter { $0 >= intermittentFloorMs }.count
        let fleetShare = Double(fleetSlowSamples) / Double(others.count)
        guard fleetShare <= laneShare / Double(relativeFactor) else { return nil }

        let p90 = percentile(samples, 0.9)
        return SlowWorkerFinding(worker: worker, samples: samples.count,
                                 kind: .intermittent(slowSamples: slowSamples, p90Ms: p90,
                                                     fleetSlowSamples: fleetSlowSamples, fleetSamples: others.count))
    }

    private static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func percentile(_ values: [Int], _ fraction: Double) -> Int {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = (Double(sorted.count - 1) * fraction).rounded()
        return sorted[Int(rank)]
    }
}
