// FM(Foundation Models)呼び出しの回数・レイテンシ・成否をプロセス内で集計する。
//
// 目的は2つ:
// (1) FM が全滅していても機能が黙って無効化されることの検知。occlusion-guard・heal・screenLooksLike は
//     いずれも FM 失敗時に nil を返して素通りする契約(呼び出し側が失敗を握りつぶす)なので、
//     集計しないと実行結果からは正常時と区別できない。
// (2) FM の実行コストの可視化。**約1回/秒の頭打ちは FMLock の直列化の上限であって FM 自体の
//     天井ではない**(実測と反証は Sources/FTCore/FMLock.swift 冒頭が正)。ANE 負荷率では測れない
//     (DIE_n_ANE0 は電源状態の1ビットで、FM 実行中は 1.00 に張り付く)ため、回数とレイテンシで測る。
//     gateWait* は FMLock.acquire() で実際に待たされた時間 —— 直列化を緩める判断材料
//     (待ちがほぼ0なら緩めても解放されるものが無い)
//
// FTCore は FoundationModels に依存しないため、記録は FTFoundationModels の各呼び出し箇所から行う
// (依存方向は FTFoundationModels → FTCore の一方向)。集計はプロセス単位。シナリオは FTScenarioRunner の
// 別プロセスで走るので、親へは scenarioFinished イベントの fm フィールドで運ぶ
// (ScenarioEvent.fm → ScenarioRecordBuilder → ScenarioRunRecord.fm → 結果 JSON)。

import Foundation

/// FM 呼び出しの用途別実測。用途キーは "occlusion" / "heal" / "screenLooksLike"
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
    /// 最初の失敗の内容(以降は捨てる。同一原因が連続するため)。**失敗が1件も無ければ nil**。
    /// これが無いと `failures` の件数しか残らず、**なぜ落ちたかを事後に特定できない**
    /// (2026-09-01: M1Ultra だけ 12% 失敗する調査で、合成負荷では再現せず理由を追えなかった)
    public var firstError: String?
    /// FMGate が FMLock.acquire() で実際に待たされた合計/p50/max。呼び出しコスト(totalMs 等)とは別物 ——
    /// 直列化を緩める判断材料(docs/results-json.md)
    public var gateWaitTotalMs: Int
    public var gateWaitP50Ms: Int
    public var gateWaitMaxMs: Int
    /// FMGate で止められ FM を呼ばずに諦めた回数(FMHealth.recordSkip)。guard が何回
    /// 静かに無効化されたかを事後に確認する材料(docs/results-json.md)
    public var skipped: Int

    public init(calls: Int, failures: Int, totalMs: Int, p50Ms: Int, maxMs: Int,
                byKind: [String: FMKindUsage],
                gateWaitTotalMs: Int = 0, gateWaitP50Ms: Int = 0, gateWaitMaxMs: Int = 0,
                skipped: Int = 0, firstError: String? = nil) {
        self.calls = calls
        self.failures = failures
        self.totalMs = totalMs
        self.p50Ms = p50Ms
        self.maxMs = maxMs
        self.byKind = byKind
        self.gateWaitTotalMs = gateWaitTotalMs
        self.gateWaitP50Ms = gateWaitP50Ms
        self.gateWaitMaxMs = gateWaitMaxMs
        self.skipped = skipped
        self.firstError = firstError
    }

    // 手書き: 古い結果 JSON(gateWait*/skipped 欄が無い)を読めなくしないため、欠落を 0 で埋める。
    // encode(to:) は synthesized のまま(全欄を書く)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        calls = try container.decode(Int.self, forKey: .calls)
        failures = try container.decode(Int.self, forKey: .failures)
        totalMs = try container.decode(Int.self, forKey: .totalMs)
        p50Ms = try container.decode(Int.self, forKey: .p50Ms)
        maxMs = try container.decode(Int.self, forKey: .maxMs)
        byKind = try container.decode([String: FMKindUsage].self, forKey: .byKind)
        gateWaitTotalMs = try container.decodeIfPresent(Int.self, forKey: .gateWaitTotalMs) ?? 0
        gateWaitP50Ms = try container.decodeIfPresent(Int.self, forKey: .gateWaitP50Ms) ?? 0
        gateWaitMaxMs = try container.decodeIfPresent(Int.self, forKey: .gateWaitMaxMs) ?? 0
        skipped = try container.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        firstError = try container.decodeIfPresent(String.self, forKey: .firstError)
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
    private static var gateWaitMs: [Double] = []

    /// FM 呼び出し1件を記録する。kind は "occlusion" / "heal" / "screenLooksLike"
    public static func record(kind: String, ms: Double, ok: Bool, error: String? = nil) {
        lock.lock()
        samples[kind, default: []].append(Sample(ms: ms, ok: ok))
        if !ok, firstError == nil, let error {
            firstError = String(error.prefix(300))
        }
        lock.unlock()
        // サーキットブレーカへの通知はここに集約する(呼び出し側に増やさない)
        if ok { FMBreaker.recordSuccess() } else { FMBreaker.recordFailure() }
        // ファイル I/O を伴うため必ずロックの外側で呼ぶ(FMUsageLedger.record の doc 参照)
        FMUsageLedger.record(ok: ok, ms: ms)
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

    /// FMGate.enter() が FMLock.acquire() で実際に待たされた時間。**取得できた回だけ**呼ぶ
    /// (timeout で諦めた回は recordSkip の役目 —— 待ち時間として混ぜない)
    public static func recordGateWait(ms: Double) {
        lock.lock()
        defer { lock.unlock() }
        gateWaitMs.append(ms)
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
            let ms = list.map { $0.ms }
            byKind[kind] = FMKindUsage(
                calls: list.count, failures: list.filter { !$0.ok }.count,
                totalMs: Self.totalMs(ms), p50Ms: Self.percentileMs(ms, 0.5),
                maxMs: Self.maxMs(ms))
        }
        let allMs = all.map { $0.ms }
        return FMUsageRecord(
            calls: all.count, failures: all.filter { !$0.ok }.count,
            totalMs: Self.totalMs(allMs), p50Ms: Self.percentileMs(allMs, 0.5),
            maxMs: Self.maxMs(allMs), byKind: byKind,
            gateWaitTotalMs: Self.totalMs(gateWaitMs), gateWaitP50Ms: Self.percentileMs(gateWaitMs, 0.5),
            gateWaitMaxMs: Self.maxMs(gateWaitMs), skipped: skipped, firstError: firstError)
    }

    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        firstError = nil
        skipped = 0
        gateWaitMs.removeAll()
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
                + "occlusion-guard (the default requireVisible of exist), self-healing and screenLooksLike were "
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

    private static func totalMs(_ list: [Double]) -> Int {
        Int(list.reduce(0.0, +).rounded())
    }

    private static func maxMs(_ list: [Double]) -> Int {
        Int((list.max() ?? 0).rounded())
    }

    /// 線形補間なしの単純パーセンタイル(サンプル数が少ないため十分)。空なら 0(不明ではなく事実)
    private static func percentileMs(_ list: [Double], _ p: Double) -> Int {
        guard !list.isEmpty else { return 0 }
        let sorted = list.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count) * p)))
        return Int(sorted[index].rounded())
    }
}
