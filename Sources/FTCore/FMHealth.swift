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

    /// FM 呼び出し1件を記録する。kind は "occlusion" / "heal" / "screenIs"
    public static func record(kind: String, ms: Double, ok: Bool, error: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        samples[kind, default: []].append(Sample(ms: ms, ok: ok))
        if !ok, firstError == nil, let error {
            firstError = String(error.prefix(300))
        }
    }

    public static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let all = samples.values.flatMap { $0 }
        return Snapshot(successes: all.filter { $0.ok }.count,
                        failures: all.filter { !$0.ok }.count,
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
    }

    /// 実行後に出す失敗警告(1行目=要約、2行目=最初のエラー)。失敗が無ければ nil
    public static func warningText() -> String? {
        let s = snapshot()
        guard s.failures > 0 else { return nil }
        var text: String
        if s.allFailed {
            text = "⚠️ FM 呼び出しが全て失敗しました(\(s.failures)件)。"
                + "occlusion-guard(exist の既定 requireVisible)・自己修復・screenIs は"
                + "この実行では無効でした(失敗は握りつぶされ pass 扱いになります)"
        } else {
            text = "⚠️ FM 呼び出しの一部が失敗しました(失敗\(s.failures)件 / 成功\(s.successes)件)。"
                + "該当ステップのガードは素通りしています"
        }
        if let e = s.firstError { text += "\n   最初のエラー: \(e)" }
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
