import Foundation

/// マシンの健全性で数える StepNote(ダッシュボードの「OCR 注記」「Vision 注記」列)。
/// 文字列リテラルでなく case から作る(StepNote.swift 冒頭の理由)
public enum MachineHealthNotes {
    public static let ocr: Set<StepNote> = [
        .ocrBudgetExhausted, .ocrCompileCapped, .ocrCompileWaited, .ocrShortcutNotReady,
        .ocrShortcutBusy, .ocrReadWhatFMMissed, .fmReadWhatOCRMissed, .fmEmptyTranscriptOnInk,
    ]
    public static let vision: Set<StepNote> = [
        .visionAnomalyRetried, .visionHelperRescued, .visionHelperUnavailable,
        .visionClassifierUnavailable, .checkStateClassifierFailed,
    ]
    /// notes のキー(rawValue)として数える全集合
    public static let tracked: Set<String> = Set((ocr.union(vision)).map(\.rawValue))
}

extension RunResultsQuery {
    public struct LastFMDead: Codable, Sendable, Equatable {
        /// run.startedAt
        public let at: String
        /// run.fmDead(経路)
        public let paths: [String]
        /// run.fmDeadReason
        public let reason: String?
    }

    public struct LastFMError: Codable, Sendable, Equatable {
        /// record.startedAt
        public let at: String
        public let scenarioID: String
        /// record.fm.firstError
        public let message: String
    }

    public struct MachineFMUsage: Codable, Sendable, Equatable {
        /// fm を持つ記録の数
        public let scenarios: Int
        public let calls: Int
        public let failures: Int
        public let retries: Int
        public let retrySuccesses: Int
        public let skipped: Int
        public let totalMs: Int
        /// 記録ごとの maxMs の最大
        public let maxMs: Int
        public let gateWaitTotalMs: Int
        public let gateWaitMaxMs: Int
        /// firstError を持つ記録のうち startedAt 最大のもの
        public let lastError: LastFMError?
    }

    /// 機械(host)ごとの FM / OCR / Vision の健全性(docs/results-json.md §マシンの健全性)。
    /// **欠けている値は nil**(0 で埋めない = 観測なしと発生なしを混ぜない)
    public struct MachineHealthRow: Codable, Sendable, Equatable {
        public let host: String
        public let runs: Int
        public let lastRunAt: String?
        public let fmDeadRuns: Int
        public let lastFMDead: LastFMDead?
        public let guarded: Int?
        public let guardSkipped: Int?
        public let guardStaleFrame: Int?
        public let fm: MachineFMUsage?
        /// 追跡する StepNote の rawValue → 出現したステップ数(0 のキーは入れない)
        public let notes: [String: Int]
        public let pacedSteps: Int?
        public let pacedMs: Int?
    }

    private struct MachineHealthAccumulator {
        var runs = 0
        var lastRunAt: String?
        var fmDeadRuns = 0
        var lastFMDead: LastFMDead?
        var guarded: Int?
        var guardSkipped: Int?
        var guardStaleFrame: Int?
        var fmScenarios = 0
        var calls = 0, failures = 0, retries = 0, retrySuccesses = 0, skipped = 0, totalMs = 0
        var maxMs = 0, gateWaitTotalMs = 0, gateWaitMaxMs = 0
        var lastError: LastFMError?
        var notes: [String: Int] = [:]
        var pacedSteps: Int?
        var pacedMs: Int?
    }

    /// `runs`/`records` は呼び手が既に窓で絞ったもの。窓に run.json か記録が1つでもある host は
    /// **全部 0 でも出す**(「事象なし」と「行なし」を区別する)
    public static func machineHealth(runs: [RunMetaRecord], records: [ScenarioRunRecord]) -> [MachineHealthRow] {
        var byHost: [String: MachineHealthAccumulator] = [:]
        func add(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }

        for run in runs {
            var acc = byHost[run.host] ?? MachineHealthAccumulator()
            acc.runs += 1
            if acc.lastRunAt == nil || run.startedAt > acc.lastRunAt! { acc.lastRunAt = run.startedAt }
            if let dead = run.fmDead, !dead.isEmpty {
                acc.fmDeadRuns += 1
                if acc.lastFMDead == nil || run.startedAt > acc.lastFMDead!.at {
                    acc.lastFMDead = LastFMDead(at: run.startedAt, paths: dead, reason: run.fmDeadReason)
                }
            }
            acc.guarded = add(acc.guarded, run.guarded)
            acc.guardSkipped = add(acc.guardSkipped, run.guardSkipped)
            acc.guardStaleFrame = add(acc.guardStaleFrame, run.guardStaleFrame)
            byHost[run.host] = acc
        }

        for record in records {
            var acc = byHost[record.host] ?? MachineHealthAccumulator()
            if let fm = record.fm {
                acc.fmScenarios += 1
                acc.calls += fm.calls
                acc.failures += fm.failures
                acc.retries += fm.retries
                acc.retrySuccesses += fm.retrySuccesses
                acc.skipped += fm.skipped
                acc.totalMs += fm.totalMs
                acc.maxMs = max(acc.maxMs, fm.maxMs)
                acc.gateWaitTotalMs += fm.gateWaitTotalMs
                acc.gateWaitMaxMs = max(acc.gateWaitMaxMs, fm.gateWaitMaxMs)
                if let message = fm.firstError, acc.lastError == nil || record.startedAt > acc.lastError!.at {
                    acc.lastError = LastFMError(at: record.startedAt, scenarioID: record.scenarioID, message: message)
                }
            }
            for step in record.timeline ?? [] {
                // 1ステップに同じ注記が重複しても1回と数える
                for note in Set(step.notes ?? []) where MachineHealthNotes.tracked.contains(note) {
                    acc.notes[note, default: 0] += 1
                }
            }
            acc.pacedSteps = add(acc.pacedSteps, record.steps.paced)
            acc.pacedMs = add(acc.pacedMs, record.steps.pacedMs)
            byHost[record.host] = acc
        }

        return byHost.map { host, acc in
            MachineHealthRow(
                host: host, runs: acc.runs, lastRunAt: acc.lastRunAt, fmDeadRuns: acc.fmDeadRuns,
                lastFMDead: acc.lastFMDead, guarded: acc.guarded, guardSkipped: acc.guardSkipped,
                guardStaleFrame: acc.guardStaleFrame,
                fm: acc.fmScenarios == 0 ? nil : MachineFMUsage(
                    scenarios: acc.fmScenarios, calls: acc.calls, failures: acc.failures,
                    retries: acc.retries, retrySuccesses: acc.retrySuccesses, skipped: acc.skipped,
                    totalMs: acc.totalMs, maxMs: acc.maxMs, gateWaitTotalMs: acc.gateWaitTotalMs,
                    gateWaitMaxMs: acc.gateWaitMaxMs, lastError: acc.lastError),
                notes: acc.notes, pacedSteps: acc.pacedSteps, pacedMs: acc.pacedMs)
        }
        .sorted { $0.host < $1.host }
    }

    /// プロジェクトごとに `machineHealth` した行を合わせる。**`parts` を入力の並び(run・記録を連結した順)で渡せば、
    /// 連結した入力をまとめて `machineHealth` した結果と一致する** —— 最新の取り方は `>`(同時刻は先の側が残る)なので、
    /// 並びを変えると同時刻の lastFMDead / lastError が入れ替わる(`MachineHealthMergeTests` が等価を固定)
    public static func mergedMachineHealth(_ parts: [[MachineHealthRow]]) -> [MachineHealthRow] {
        func add(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
        func later<T>(_ a: T?, _ b: T?, at: (T) -> String) -> T? {
            guard let a else { return b }
            guard let b else { return a }
            return at(b) > at(a) ? b : a
        }
        var byHost: [String: MachineHealthRow] = [:]
        for row in parts.joined() {
            guard let acc = byHost[row.host] else {
                byHost[row.host] = row
                continue
            }
            let fm: MachineFMUsage?
            switch (acc.fm, row.fm) {
            case (nil, nil): fm = nil
            case (let one?, nil), (nil, let one?): fm = one
            case (let a?, let b?):
                fm = MachineFMUsage(
                    scenarios: a.scenarios + b.scenarios, calls: a.calls + b.calls, failures: a.failures + b.failures,
                    retries: a.retries + b.retries, retrySuccesses: a.retrySuccesses + b.retrySuccesses,
                    skipped: a.skipped + b.skipped, totalMs: a.totalMs + b.totalMs, maxMs: max(a.maxMs, b.maxMs),
                    gateWaitTotalMs: a.gateWaitTotalMs + b.gateWaitTotalMs,
                    gateWaitMaxMs: max(a.gateWaitMaxMs, b.gateWaitMaxMs),
                    lastError: later(a.lastError, b.lastError, at: \.at))
            }
            byHost[row.host] = MachineHealthRow(
                host: row.host, runs: acc.runs + row.runs,
                lastRunAt: later(acc.lastRunAt, row.lastRunAt, at: { $0 }),
                fmDeadRuns: acc.fmDeadRuns + row.fmDeadRuns,
                lastFMDead: later(acc.lastFMDead, row.lastFMDead, at: \.at),
                guarded: add(acc.guarded, row.guarded), guardSkipped: add(acc.guardSkipped, row.guardSkipped),
                guardStaleFrame: add(acc.guardStaleFrame, row.guardStaleFrame), fm: fm,
                notes: acc.notes.merging(row.notes, uniquingKeysWith: +),
                pacedSteps: add(acc.pacedSteps, row.pacedSteps), pacedMs: add(acc.pacedMs, row.pacedMs))
        }
        return byHost.values.sorted { $0.host < $1.host }
    }
}
