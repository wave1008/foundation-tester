// machineHealth をプロジェクトごとに分けて合わせても、連結してまとめて数えた結果と一致すること
// (`RunResultsQuery.mergedMachineHealth`)と、他プロジェクトの部分結果のキャッシュ(`MachineHealthPartialCache`)の
// 命中・外れを固定する

import Foundation
import XCTest
@testable import FTCore

final class MachineHealthMergeTests: XCTestCase {

    /// 決まった種の線形合同法(乱数のデータを毎回同じにする)
    private struct Seeded {
        var state: UInt64
        mutating func next(_ upper: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(upper))
        }
    }

    private func meta(_ id: String, at: String, host: String, fmDead: [String]?, reason: String?,
                      guarded: Int?) -> RunMetaRecord {
        RunMetaRecord(runID: id, project: "P", profile: nil, host: host, trigger: "cli", startedAt: at,
                      finishedAt: nil, total: 1, passed: nil, failed: nil, measurementInvalid: nil,
                      workerAnomalies: nil, runGroup: nil, performanceMode: nil,
                      fmDead: fmDead, fmDeadReason: reason,
                      guarded: guarded, guardSkipped: guarded.map { $0 / 2 }, guardStaleFrame: nil)
    }

    private func record(_ id: String, at: String, host: String, fm: FMUsageRecord?, notes: [String]?,
                        paced: Int?) -> ScenarioRunRecord {
        ScenarioRunRecord(
            runID: "", scenarioID: id, title: nil, platform: "ios", worker: nil, host: host,
            passed: true, timedOut: nil, startedAt: at, durationMs: 1, scenes: [],
            steps: StepCountsRecord(total: 1, passed: 1, paced: paced, pacedMs: paced.map { $0 * 10 }),
            failedSteps: nil, fixSuggestions: nil, errorLogs: nil, fm: fm,
            timeline: notes.map { [TimelineStepRecord(index: 1, description: "s", status: "passed", notes: $0)] },
            appCrash: nil)
    }

    private func fm(calls: Int, maxMs: Int, error: String?) -> FMUsageRecord {
        FMUsageRecord(calls: calls, failures: calls / 3, totalMs: calls * 7, p50Ms: 0, maxMs: maxMs,
                      byKind: [:], gateWaitTotalMs: calls, gateWaitMaxMs: maxMs / 2, skipped: 0,
                      firstError: error, retries: 1, retrySuccesses: 0)
    }

    /// 3プロジェクトぶんの乱数のデータ。時刻は 4 通りしか無い = 同時刻が多数(最新の取り方の順序依存を踏む)
    private func parts(seed: UInt64) -> [(runs: [RunMetaRecord], records: [ScenarioRunRecord])] {
        var rng = Seeded(state: seed)
        let hosts = ["mac1", "mac2", "mac3"]
        let times = ["2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z", "2026-01-04T00:00:00Z"]
        let notes = ["ocr-budget-exhausted", "vision-anomaly-retried", "settle-capped", "fm-empty-transcript-on-ink"]
        return (0..<3).map { project in
            let runs = (0..<rng.next(8)).map { i in
                meta("P\(project)R\(i)", at: times[rng.next(4)], host: hosts[rng.next(3)],
                     fmDead: rng.next(3) == 0 ? ["text\(project)-\(i)"] : (rng.next(2) == 0 ? [] : nil),
                     reason: "reason \(project)-\(i)", guarded: rng.next(2) == 0 ? rng.next(9) : nil)
            }
            let records = (0..<rng.next(12)).map { i in
                record("P\(project).S\(i)", at: times[rng.next(4)], host: hosts[rng.next(3)],
                       fm: rng.next(2) == 0 ? fm(calls: rng.next(20), maxMs: rng.next(900),
                                                 error: rng.next(2) == 0 ? "err \(project)-\(i)" : nil) : nil,
                       notes: rng.next(3) == 0 ? nil : [notes[rng.next(4)], notes[rng.next(4)]],
                       paced: rng.next(2) == 0 ? rng.next(5) : nil)
            }
            return (runs, records)
        }
    }

    func testMergedPartsEqualTheWholeAcrossSeeds() {
        for seed in UInt64(1)...200 {
            let parts = parts(seed: seed)
            let whole = RunResultsQuery.machineHealth(runs: parts.flatMap(\.runs), records: parts.flatMap(\.records))
            let merged = RunResultsQuery.mergedMachineHealth(
                parts.map { RunResultsQuery.machineHealth(runs: $0.runs, records: $0.records) })
            XCTAssertEqual(merged, whole, "seed \(seed)")
        }
    }

    /// 同時刻の最新は先の部分が残る(連結したときの `>` と同じ)
    func testTieKeepsTheEarlierPart() {
        let at = "2026-01-02T00:00:00Z"
        let first = RunResultsQuery.machineHealth(
            runs: [meta("A", at: at, host: "mac1", fmDead: ["first"], reason: nil, guarded: nil)], records: [])
        let second = RunResultsQuery.machineHealth(
            runs: [meta("B", at: at, host: "mac1", fmDead: ["second"], reason: nil, guarded: nil)], records: [])
        XCTAssertEqual(RunResultsQuery.mergedMachineHealth([first, second])[0].lastFMDead?.paths, ["first"])
    }

    // MARK: - MachineHealthPartialCache

    private func tempStateDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mh-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func input() -> (runs: [RunMetaRecord], records: [ScenarioRunRecord]) {
        ([meta("R1", at: "2026-01-02T00:00:00Z", host: "mac1", fmDead: nil, reason: nil, guarded: 3)],
         [record("S.a", at: "2026-01-03T00:00:00Z", host: "mac1", fm: nil, notes: nil, paced: nil)])
    }

    private func part(_ stateDir: URL, since: String = "90d", sinceKey: String = "2026-01-01T00:00:00Z",
                      digest: String = "d1", readCache: Bool = true, calls: inout Int) -> MachineHealthPartialCache.Part {
        var count = calls
        defer { calls = count }
        return MachineHealthPartialCache.part(
            stateDir: stateDir, since: since, sinceKey: sinceKey, scanDigest: digest,
            executable: URL(fileURLWithPath: #filePath), readCache: readCache) {
            count += 1
            return input()
        }
    }

    func testPartialCacheHitsWithoutRecomputing() throws {
        let dir = try tempStateDir()
        var calls = 0
        let miss = part(dir, calls: &calls)
        XCTAssertFalse(miss.fromCache)
        XCTAssertEqual(miss.oldestIncludedStartedAt, "2026-01-02T00:00:00Z")
        let hit = part(dir, sinceKey: "2026-01-01T12:00:00Z", calls: &calls)
        XCTAssertTrue(hit.fromCache)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(hit.rows, miss.rows)
        XCTAssertEqual(hit.rows, RunResultsQuery.machineHealth(runs: input().runs, records: input().records))
    }

    /// 指紋が変わった・窓から記録が落ちた・--no-cache はどれも数え直す
    func testPartialCacheMissesOnDigestAgeOutAndNoCache() throws {
        let dir = try tempStateDir()
        var calls = 0
        _ = part(dir, calls: &calls)
        // 命中するはずの状態で読まない(--no-cache)
        XCTAssertFalse(part(dir, readCache: false, calls: &calls).fromCache)
        XCTAssertFalse(part(dir, digest: "d2", calls: &calls).fromCache)
        XCTAssertFalse(part(dir, sinceKey: "2026-01-02T12:00:00Z", digest: "d2", calls: &calls).fromCache)
        XCTAssertEqual(calls, 4)
    }

    /// since の引数ごとに別のファイル(交互に呼んでも互いを追い出さない)
    func testPartialCacheKeepsOneEntryPerSinceArgument() throws {
        let dir = try tempStateDir()
        var calls = 0
        _ = part(dir, since: "90d", calls: &calls)
        _ = part(dir, since: "16h", sinceKey: "2026-01-01T00:00:00Z", calls: &calls)
        XCTAssertTrue(part(dir, since: "90d", calls: &calls).fromCache)
        XCTAssertTrue(part(dir, since: "16h", calls: &calls).fromCache)
        XCTAssertEqual(calls, 2)
        XCTAssertNotEqual(MachineHealthPartialCache.entryURL(stateDir: dir, since: "90d"),
                          MachineHealthPartialCache.entryURL(stateDir: dir, since: "16h"))
    }

    /// 長い since の引数でもファイル名の上限を超えずに書けて命中する
    func testPartialCacheHitsWithALongSinceArgument() throws {
        let dir = try tempStateDir()
        var calls = 0
        let long = String(repeating: "2026-01-01", count: 20)
        _ = part(dir, since: long, calls: &calls)
        XCTAssertTrue(part(dir, since: long, calls: &calls).fromCache)
        XCTAssertEqual(calls, 1)
    }

    /// 窓に何も無ければ書かない(結果の無いプロジェクトに `.fleetest/` を作らない)
    func testPartialCacheDoesNotWriteAnEmptyWindow() throws {
        let parent = try tempStateDir()
        let dir = parent.appendingPathComponent(".fleetest")
        let part = MachineHealthPartialCache.part(
            stateDir: dir, since: "90d", sinceKey: "2026-01-01T00:00:00Z", scanDigest: "d1",
            executable: URL(fileURLWithPath: #filePath), readCache: true) { ([], []) }
        XCTAssertEqual(part.rows, [])
        XCTAssertNil(part.oldestIncludedStartedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
