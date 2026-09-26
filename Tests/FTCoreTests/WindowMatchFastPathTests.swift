import XCTest
@testable import FTCore

/// `RunResultsStore.windowMatch`(scanRuns と RunRecordPack 経由の run.json 判定が共有する
/// since/until 判定)の文字列比較の近道(`isCanonicalISO8601Z`)。近道は
/// `ISO8601DateFormatter.date(from:)` を避けるための最適化なので、**近道を通っても通らなくても
/// 判定が変わらないこと**をここで固定する(E2E-CMP の run.json 5,700 件で計測時間の主要因だった
/// —— docs/results-json.md §出力キャッシュ)。
final class WindowMatchFastPathTests: XCTestCase {
    private let formatter = ISO8601DateFormatter()

    private func date(_ iso: String) -> Date {
        formatter.date(from: iso)!
    }

    // MARK: - isCanonicalISO8601Z

    func testCanonicalFormIsRecognized() {
        XCTAssertTrue(RunResultsStore.isCanonicalISO8601Z("2026-01-01T00:00:00Z"))
        XCTAssertTrue(RunResultsStore.isCanonicalISO8601Z("2026-12-31T23:59:59Z"))
    }

    func testNonCanonicalFormsAreRejected() {
        XCTAssertFalse(RunResultsStore.isCanonicalISO8601Z("2026-01-01T00:00:00.123Z"), "fractional seconds")
        XCTAssertFalse(RunResultsStore.isCanonicalISO8601Z("2026-01-01T00:00:00+09:00"), "non-Z offset")
        XCTAssertFalse(RunResultsStore.isCanonicalISO8601Z("2026-01-01 00:00:00Z"), "wrong separator")
        XCTAssertFalse(RunResultsStore.isCanonicalISO8601Z("not-a-date"))
        XCTAssertFalse(RunResultsStore.isCanonicalISO8601Z(""))
        XCTAssertFalse(RunResultsStore.isCanonicalISO8601Z("2026-01-01T00:00:00"), "missing Z")
    }

    // MARK: - windowMatch: 両方 nil なら常に included(パース自体をしない)

    func testNoWindowAlwaysIncludesEvenGarbage() {
        XCTAssertEqual(
            RunResultsStore.windowMatch(startedAt: "garbage", since: nil, until: nil,
                                        sinceKey: nil, untilKey: nil, formatter: formatter),
            .included)
    }

    // MARK: - windowMatch: 正準形(近道)と非正準形(実パース)が同じ判定を返す

    /// since/until の境界そのものを正準形(ミリ秒無し)に取り、境界の前後1秒それぞれで
    /// 近道(文字列比較)と実パース(Date比較)が同じ分類を返すことを確認する。
    /// 境界を正準形に揃えるのは、`windowKey` が境界をミリ秒無しへ丸めるため生じる
    /// ±1秒未満の誤差(既存の doc に記載済みの前提)をこのテストでは踏まないようにするため
    func testCanonicalAndParsedPathsAgreeAroundTheBoundary() {
        let since = date("2026-06-01T00:00:00Z")
        let until = date("2026-06-30T00:00:00Z")
        let sinceKey = RunResultsStore.windowKey(since)
        let untilKey = RunResultsStore.windowKey(until)

        let cases: [(String, RunResultsStore.WindowMatch)] = [
            ("2026-05-31T23:59:59Z", .excluded),
            ("2026-06-01T00:00:00Z", .included),
            ("2026-06-01T00:00:01Z", .included),
            ("2026-06-29T23:59:59Z", .included),
            ("2026-06-30T00:00:00Z", .included),
            ("2026-06-30T00:00:01Z", .excluded),
        ]
        for (startedAt, expected) in cases {
            XCTAssertTrue(RunResultsStore.isCanonicalISO8601Z(startedAt), "sanity: \(startedAt) must be canonical")
            // 近道(文字列比較)
            XCTAssertEqual(RunResultsStore.windowMatch(startedAt: startedAt, since: since, until: until,
                                                       sinceKey: sinceKey, untilKey: untilKey, formatter: formatter),
                           expected, "fast path: \(startedAt)")
            // 実パース(Date比較)。"Z" を "+00:00" に変えると同じ瞬間を指す非正準形になり、
            // `ISO8601DateFormatter` の既定オプションでもパースできる(ミリ秒付きは既定では
            // パース不能 = 常に unparseable になるので使えない。実測で確認済み)ので遅い経路を
            // 強制的に通せる
            let offsetForm = String(startedAt.dropLast()) + "+00:00"
            XCTAssertFalse(RunResultsStore.isCanonicalISO8601Z(offsetForm), "sanity: forced onto the slow path")
            XCTAssertEqual(RunResultsStore.windowMatch(startedAt: offsetForm, since: since, until: until,
                                                       sinceKey: sinceKey, untilKey: untilKey, formatter: formatter),
                           expected, "slow path: \(offsetForm)")
        }
    }

    func testUnparseableStartedAtIsUnparseableOnlyWhenWindowed() {
        XCTAssertEqual(
            RunResultsStore.windowMatch(startedAt: "not-a-date", since: date("2026-06-01T00:00:00Z"), until: nil,
                                        sinceKey: "2026-06-01T00:00:00Z", untilKey: nil, formatter: formatter),
            .unparseable)
        XCTAssertEqual(
            RunResultsStore.windowMatch(startedAt: "not-a-date", since: nil, until: nil,
                                        sinceKey: nil, untilKey: nil, formatter: formatter),
            .included)
    }

    // MARK: - scanRuns 自体が近道と実パースで同じ結果を返す(統合)

    func testScanRunsAgreesForCanonicalAndOffsetStartedAt() throws {
        let repoRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WindowMatchFastPathTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        let project = TestProject(name: "SampleApp", rootURL: repoRoot.appendingPathComponent("TestProjects/SampleApp"))
        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)

        func writeRun(runID: String, startedAt: String) {
            let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: runID)
            RunResultsStore.writeMeta(
                RunMetaRecord(runID: runID, project: "SampleApp", profile: nil,
                             host: "testmachine", trigger: "cli", startedAt: startedAt),
                runDir: runDir)
        }
        // 正準形(近道)と非正準形("+00:00" オフセット。実パース)を境界の内外に混在させる。
        // どちらも同じ瞬間を指すので、窓判定の結果は形式に関わらず揃うはず
        writeRun(runID: "20260601-000000Z-mach-0001", startedAt: "2026-06-01T00:00:00Z")
        writeRun(runID: "20260601-000000Z-mach-0002", startedAt: "2026-06-01T00:00:00+00:00")
        writeRun(runID: "20260531-235959Z-mach-0003", startedAt: "2026-05-31T23:59:59Z")
        writeRun(runID: "20260531-235959Z-mach-0004", startedAt: "2026-05-31T23:59:59+00:00")

        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z"))
        let runs = RunResultsStore.scanRuns(resultsDir: resultsDir, since: since)
        XCTAssertEqual(Set(runs.map(\.runID)),
                       ["20260601-000000Z-mach-0001", "20260601-000000Z-mach-0002"])
    }
}
