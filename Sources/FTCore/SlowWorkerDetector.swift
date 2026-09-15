// SlowWorkerDetector.swift
// 「台そのものが遅い」ことの**観測だけ**を行う純粋関数(自動修復・除外はしない)。
// 根拠(2026-09-15 の3時間負荷テスト): シミュレータ1台だけが3 run連続で in-app snapshot
// 4.3〜4.4秒に張り付いた(通常は数十ms。他7台は15ラウンドで2秒超が3回以下)。ホストCPUでは
// 説明が付かず(中央値56%・前後のラウンドと同等)、XCUITestランナーを建て直しても直らなかった
// (遅いのはランナーではなく台)。4.4秒はステップtimeout(`FTCore.DefaultWait.seconds`=5秒)未満
// なので既存の `slow-snapshot` 注記(timeout超過)は立たず、所要以外に痕跡が残らない。
//
// 入力は ScenarioRunRecord.timeline の snapshotMs(worker ごとに束ねる)。他の欄
// (actionMs/waitMs 等)は対象にしない —— 実測の劣化は snapshot だけに出ていたため。

import Foundation

/// 1台の遅さの観測結果。除外・修復の判断材料ではなく事実(中央値・標本数)だけを持つ。
public struct SlowWorkerFinding: Sendable, Equatable {
    /// ScenarioRunRecord.worker と同じ文字列("<platform>:<デバイス論理名>")
    public let worker: String
    public let medianMs: Int
    /// 同じ run の他ワーカー全体(プールした標本)の中央値
    public let fleetMedianMs: Int
    public let samples: Int

    public init(worker: String, medianMs: Int, fleetMedianMs: Int, samples: Int) {
        self.worker = worker
        self.medianMs = medianMs
        self.fleetMedianMs = fleetMedianMs
        self.samples = samples
    }

    /// run.json `slowWorkers` 用の表示1行(degradedWorkers と同じ「事実だけの1行」規律)
    public var summary: String {
        "\(worker): median snapshot \(medianMs)ms over \(samples) samples (other lanes \(fleetMedianMs)ms)"
    }

    /// CLI 末尾の警告1行(英語)。**FrozenVerdict とは別の観測であること**と
    /// **自動では何もしないこと**を含める(受け手が誤って「ツールが直した」と読まないため)
    public var consoleWarning: String {
        "⚠️ slow lane: \(worker) answered snapshots in \(medianMs)ms (median of \(samples))"
            + " while other lanes took \(fleetMedianMs)ms — the simulator itself is slow"
            + " (not the runner); consider rebooting it"
    }
}

public enum SlowWorkerDetector {
    /// 判定に要る最小標本数。1シナリオの短い台本で偶然の1枚に引っ張られないための下限。
    /// 根拠: 実測の劣化は41ステップ中18回・67ステップ中23回で標本は十分にあった
    public static let minSamples = 8

    /// 「遅い」と言うための相対条件(他ワーカー全体の中央値の何倍か)。相対条件だけだと
    /// 全台が同じ速さで遅いrun(ホスト負荷)を1台のせいにしてしまうので absoluteFloorMs と併用する
    public static let relativeFactor = 10

    /// 「遅い」と言うための絶対条件(ms)。通常のin-app snapshot(数十ms)の1桁上、かつ
    /// ステップtimeout(`FTCore.DefaultWait.seconds`=5秒)の1/5 —— 既存の`slow-snapshot`注記
    /// (timeout超過でしか立たない)が原理的に見えない帯をここで拾う。絶対条件が無いと
    /// 元から遅い環境(実機USB等)で毎回鳴ってしまう
    public static let absoluteFloorMs = 1000

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
            guard workerMedian >= absoluteFloorMs, workerMedian >= fleetMedian * relativeFactor
            else { continue }
            findings.append(SlowWorkerFinding(worker: worker, medianMs: workerMedian,
                                              fleetMedianMs: fleetMedian, samples: samples.count))
        }
        return findings
    }

    private static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
