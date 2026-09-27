// ResultsLogEntries.collect(runDir:eventsDir:scenarioFilter:) は events/ の3種
// (完走 / superseded / .inflight)をファイルだけから並べる純粋な走査。デバイス・run 実行を挟まず
// 直接ディレクトリを組み立てて検証する。

import XCTest
import FTCore
@testable import fleetest

final class ResultsLogEntriesTests: XCTestCase {

    private var runDir: URL!
    private var eventsDir: URL!

    override func setUpWithError() throws {
        runDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("results-log-entries-\(UUID().uuidString)", isDirectory: true)
        eventsDir = runDir.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: runDir)
    }

    private func writeScenario(fileName: String, scenarioID: String, worker: String? = nil) {
        let record = ScenarioRunRecord(
            scenarioID: scenarioID, platform: "ios", worker: worker, passed: true,
            startedAt: "2026-09-28T00:00:00.000Z", durationMs: 100,
            steps: StepCountsRecord(total: 1, passed: 1))
        RunResultsStore.writeScenario(record, runDir: runDir, fileName: fileName)
    }

    private func writeEventsFile(_ fileName: String, lines: [String] = ["line"],
                                 in dir: URL? = nil) {
        let dir: URL = dir ?? eventsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent(fileName),
                                                  atomically: true, encoding: .utf8)
    }

    // MARK: - 完走したシナリオ

    func testCompletedScenarioIsMatchedByFileBase() {
        writeScenario(fileName: "Login.成功する", scenarioID: "Login.成功する", worker: "ios:iPhone")
        writeEventsFile("Login.成功する.ndjson")

        let entries = ResultsLogEntries.collect(runDir: runDir, eventsDir: eventsDir, scenarioFilter: nil)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].heading, "Login.成功する (worker: ios:iPhone)")
    }

    func testScenarioWithoutMatchingEventsFileIsSkipped() {
        writeScenario(fileName: "Login.成功する", scenarioID: "Login.成功する")
        // events/Login.成功する.ndjson を書かない(この機能より前に走った run 相当)

        let entries = ResultsLogEntries.collect(runDir: runDir, eventsDir: eventsDir, scenarioFilter: nil)
        XCTAssertTrue(entries.isEmpty)
    }

    func testScenarioFilterMatchesByScenarioIDNotFileName() {
        writeScenario(fileName: "Login.成功する", scenarioID: "Login.成功する")
        writeEventsFile("Login.成功する.ndjson")
        writeScenario(fileName: "Login.失敗する", scenarioID: "Login.失敗する")
        writeEventsFile("Login.失敗する.ndjson")

        let entries = ResultsLogEntries.collect(runDir: runDir, eventsDir: eventsDir,
                                                scenarioFilter: "Login.失敗する")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].heading, "Login.失敗する")
    }

    func testRepeatedScenarioFileGetsItsOwnEntry() {
        // 凍結の再実行等で同じ scenarioID が2ファイルに分かれる(RunRecorder の "~N" サフィックス)
        writeScenario(fileName: "Login.成功する", scenarioID: "Login.成功する")
        writeEventsFile("Login.成功する.ndjson")
        writeScenario(fileName: "Login.成功する~2", scenarioID: "Login.成功する")
        writeEventsFile("Login.成功する~2.ndjson")

        let entries = ResultsLogEntries.collect(runDir: runDir, eventsDir: eventsDir, scenarioFilter: nil)
        XCTAssertEqual(entries.count, 2)
    }

    // MARK: - superseded

    func testSupersededEntryIsLabeled() {
        let supersededDir = eventsDir.appendingPathComponent("superseded")
        writeEventsFile("Login.成功する.1.ndjson", in: supersededDir)

        let entries = ResultsLogEntries.collect(runDir: runDir, eventsDir: eventsDir, scenarioFilter: nil)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].heading, "Login.成功する.1 (superseded)")
    }

    func testSupersededEntryIsFilteredByScenarioID() {
        let supersededDir = eventsDir.appendingPathComponent("superseded")
        writeEventsFile("Login.成功する.1.ndjson", in: supersededDir)
        writeEventsFile("Login.失敗する.1.ndjson", in: supersededDir)

        let entries = ResultsLogEntries.collect(runDir: runDir, eventsDir: eventsDir,
                                                scenarioFilter: "Login.成功する")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].heading, "Login.成功する.1 (superseded)")
    }

    /// "Login.成功する" で絞ったとき、prefix が同じだけの別シナリオ("Login.成功するX")の
    /// superseded を誤って拾わない(末尾の ".<k>" と "~N" を剥がしてから厳密一致で比べる)
    func testSupersededEntryDoesNotMatchOnPrefixCollision() {
        let supersededDir = eventsDir.appendingPathComponent("superseded")
        writeEventsFile("Login.成功するX.1.ndjson", in: supersededDir)

        let entries = ResultsLogEntries.collect(runDir: runDir, eventsDir: eventsDir,
                                                scenarioFilter: "Login.成功する")
        XCTAssertTrue(entries.isEmpty)
    }

    /// "~N" の連番サフィックス付きの fileBase も、剥がしてから比べる
    func testSupersededEntryMatchesAcrossRepeatSuffix() {
        let supersededDir = eventsDir.appendingPathComponent("superseded")
        writeEventsFile("Login.成功する~2.1.ndjson", in: supersededDir)

        let entries = ResultsLogEntries.collect(runDir: runDir, eventsDir: eventsDir,
                                                scenarioFilter: "Login.成功する")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].heading, "Login.成功する~2.1 (superseded)")
    }

    // MARK: - .inflight

    func testInflightEntryDiscoversScenarioFromFirstEventLine() {
        let inflightLine =
            ##"{"t":"2026-09-28T00:00:00.000Z","stream":"stdout","event":{"kind":"scenarioStarted","scenario":"Login.成功する"}}"##
        writeEventsFile(".inflight-ABCDEF.ndjson", lines: [inflightLine])

        let entries = ResultsLogEntries.collect(runDir: runDir, eventsDir: eventsDir, scenarioFilter: nil)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].heading, "Login.成功する (incomplete)")
    }

    func testInflightEntryWithUndiscoverableScenarioFallsBackToFileName() {
        writeEventsFile(".inflight-ABCDEF.ndjson", lines: ["not json"])

        let entries = ResultsLogEntries.collect(runDir: runDir, eventsDir: eventsDir, scenarioFilter: nil)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].heading, ".inflight-ABCDEF.ndjson (incomplete)")
    }

    func testInflightEntryIsExcludedByScenarioFilterWhenUndiscoverable() {
        // 言えないときは推測で含めない(欄を省く規律と同じ)
        writeEventsFile(".inflight-ABCDEF.ndjson", lines: ["not json"])

        let entries = ResultsLogEntries.collect(runDir: runDir, eventsDir: eventsDir,
                                                scenarioFilter: "Login.成功する")
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - 順序

    func testOrderIsCompletedThenSupersededThenInflight() {
        writeScenario(fileName: "A", scenarioID: "A")
        writeEventsFile("A.ndjson")
        writeEventsFile("A.1.ndjson", in: eventsDir.appendingPathComponent("superseded"))
        writeEventsFile(".inflight-X.ndjson", lines: ["not json"])

        let entries = ResultsLogEntries.collect(runDir: runDir, eventsDir: eventsDir, scenarioFilter: nil)
        XCTAssertEqual(entries.map(\.heading), ["A", "A.1 (superseded)", ".inflight-X.ndjson (incomplete)"])
    }
}
