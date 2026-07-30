// FM(Foundation Models)呼び出しの回数・レイテンシ・成否をプロセス内で集計する。
//
// 目的は2つ:
// (1) FM が全滅していても機能が黙って無効化されることの検知。occlusion-guard・heal・screenIs は
//     いずれも FM 失敗時に nil を返して素通りする契約(呼び出し側が失敗を握りつぶす)なので、
//     集計しないと実行結果からは正常時と区別できない。
// (2) FM の実行コストの可視化。実測(2026-07-22 M2 Ultra)で FM はホスト全体で直列化しており、
//     スループットは並列度によらず約 1 回/秒で頭打ち・レイテンシは並列度にほぼ正比例した
//     (逐次 1.2s → 5並列 4.7s → 10並列 9.4s)。したがって実行時間には
//     「FM 呼び出し総数 × 約1秒」の下限ができ、これはデバイス数を増やしても縮まない。
//     ANE 負荷率では測れない(DIE_n_ANE0 は電源状態の1ビットで、FM 実行中は 1.00 に張り付く)
//     ため、回数とレイテンシで測る。
//
// FTCore は FoundationModels に依存しないため、記録は FTAgent の各呼び出し箇所から行う
// (依存方向は FTAgent → FTCore の一方向)。集計はプロセス単位。シナリオは FTScenarioRunner の
// 別プロセスで走るので、親へは scenarioFinished イベントの fm フィールドで運ぶ
// (ScenarioEvent.fm → ScenarioRecordBuilder → ScenarioRunRecord.fm → 結果 JSON)。

import Foundation

/// FM 呼び出しの用途別実測。用途キーは "occlusion" / "heal" / "screenIs"
public struct FMKindUsage: Codable, Sendable {
    public var calls: Int
    public var failures: Int
    public var totalMs: Int
    public var p50Ms: Int
    public var maxMs: Int

    public init(calls: Int, failures: Int, totalMs: Int, p50Ms: Int, maxMs: Int) {
        self.calls = calls
        self.failures = failures
        self.totalMs = totalMs
        self.p50Ms = p50Ms
        self.maxMs = maxMs
    }
}

/// シナリオ1本ぶんの FM 実測。呼び出しが1件も無ければ記録しない(nil)
public struct FMUsageRecord: Codable, Sendable {
    public var calls: Int
    public var failures: Int
    /// FM に費やした合計時間。直列化するため、実行全体の下限時間の見積もりに使う
    public var totalMs: Int
    public var p50Ms: Int
    public var maxMs: Int
    public var byKind: [String: FMKindUsage]

    public init(calls: Int, failures: Int, totalMs: Int, p50Ms: Int, maxMs: Int,
                byKind: [String: FMKindUsage]) {
        self.calls = calls
        self.failures = failures
        self.totalMs = totalMs
        self.p50Ms = p50Ms
        self.maxMs = maxMs
        self.byKind = byKind
    }
}

public enum FMHealth {
    public struct Snapshot: Sendable {
        public let successes: Int
        public let failures: Int
        /// ゲート(FMGate)で止められ**呼ばずに諦めた**回数(ブレーカ作動中 or ロック待ち超過)。
        /// 失敗(FM が答えを返せなかった)とは別物なので分けて数える
        public let skipped: Int
        /// 最初に観測した失敗の内容(以降は捨てる。同一原因が連続するため)
        public let firstError: String?

        public var attempted: Int { successes + failures }
        /// 1回以上呼ばれ、かつ全滅している = 機能が黙って無効になっている
        public var allFailed: Bool { failures > 0 && successes == 0 }
    }

    private struct Sample {
        let ms: Double
        let ok: Bool
    }

    private static let lock = NSLock()
    private static var samples: [String: [Sample]] = [:]
    private static var firstError: String?
    private static var skipped = 0

    /// FM 呼び出し1件を記録する。kind は "occlusion" / "heal" / "screenIs"
    public static func record(kind: String, ms: Double, ok: Bool, error: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        samples[kind, default: []].append(Sample(ms: ms, ok: ok))
        if !ok, firstError == nil, let error {
            firstError = String(error.prefix(300))
        }
        // サーキットブレーカへの通知はここに集約する(呼び出し側に増やさない)
        if ok { FMBreaker.recordSuccess() } else { FMBreaker.recordFailure() }
    }

    /// NSError の入れ子(NSUnderlyingError / NSMultipleUnderlyingErrors)を辿って
    /// `domain(code): 説明` の連鎖に畳む。**LanguageModelError は最上位が常に
    /// `Code=-1 "The operation couldn't be completed."` で、真因は入れ子の中にしか無い**。
    /// 素の description を切り詰めると真因ごと落ちるので、記録前にこれを通す
    public static func describe(_ error: Error, limit: Int = 4) -> String {
        var parts: [String] = []
        var queue: [NSError] = [error as NSError]
        var seen = 0
        while !queue.isEmpty, seen < limit {
            let next = queue.removeFirst()
            seen += 1
            let message = next.userInfo[NSLocalizedDescriptionKey] as? String
                ?? next.localizedDescription
            parts.append("\(next.domain)(\(next.code)): \(message)")
            if let one = next.userInfo[NSUnderlyingErrorKey] as? NSError { queue.append(one) }
            if let many = next.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                queue.append(contentsOf: many)
            }
        }
        return parts.joined(separator: " ← ")
    }

    /// FMGate で止められ FM を呼ばずに諦めた 1 件を記録する(失敗にはしない)
    public static func recordSkip() {
        lock.lock()
        defer { lock.unlock() }
        skipped += 1
    }

    public static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let all = samples.values.flatMap { $0 }
        return Snapshot(successes: all.filter { $0.ok }.count,
                        failures: all.filter { !$0.ok }.count,
                        skipped: skipped,
                        firstError: firstError)
    }

    /// 結果 JSON へ載せる実測。呼び出しが1件も無ければ nil(FM を使わない実行を汚さない)
    public static func usage() -> FMUsageRecord? {
        lock.lock()
        defer { lock.unlock() }
        let all = samples.values.flatMap { $0 }
        guard !all.isEmpty else { return nil }
        var byKind: [String: FMKindUsage] = [:]
        for (kind, list) in samples where !list.isEmpty {
            byKind[kind] = FMKindUsage(
                calls: list.count, failures: list.filter { !$0.ok }.count,
                totalMs: Self.totalMs(list), p50Ms: Self.percentileMs(list, 0.5),
                maxMs: Self.maxMs(list))
        }
        return FMUsageRecord(
            calls: all.count, failures: all.filter { !$0.ok }.count,
            totalMs: Self.totalMs(all), p50Ms: Self.percentileMs(all, 0.5),
            maxMs: Self.maxMs(all), byKind: byKind)
    }

    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        firstError = nil
        skipped = 0
    }

    /// 実行後に出す失敗警告(1行目=要約、2行目=最初のエラー)。失敗が無ければ nil
    public static func warningText() -> String? {
        let s = snapshot()
        guard s.failures > 0 || s.skipped > 0 else { return nil }
        var text: String
        if s.failures == 0 {
            return "⚠️ Skipped \(s.skipped) FM call(s)"
                + " (circuit breaker open, or the serialisation wait ran out. "
                + "The guards on those steps passed through unchecked)"
        }
        if s.allFailed {
            text = "⚠️ Every FM call failed (\(s.failures)). "
                + "occlusion-guard (the default requireVisible of exist), self-healing and screenIs were "
                + "effectively disabled for this run (failures are swallowed and treated as pass)"
        } else {
            text = "⚠️ Some FM calls failed (\(s.failures) failed / \(s.successes) succeeded). "
                + "The guards on those steps passed through unchecked"
        }
        if s.skipped > 0 {
            text += ". A further \(s.skipped) were skipped"
                + " (circuit breaker open, or the serialisation wait ran out)"
        }
        if let e = s.firstError { text += "\n   First error: \(e)" }
        return text
    }

    private static func totalMs(_ list: [Sample]) -> Int {
        Int(list.reduce(0.0) { $0 + $1.ms }.rounded())
    }

    private static func maxMs(_ list: [Sample]) -> Int {
        Int((list.map { $0.ms }.max() ?? 0).rounded())
    }

    /// 線形補間なしの単純パーセンタイル(サンプル数が少ないため十分)
    private static func percentileMs(_ list: [Sample], _ p: Double) -> Int {
        guard !list.isEmpty else { return 0 }
        let sorted = list.map { $0.ms }.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count) * p)))
        return Int(sorted[index].rounded())
    }
}
