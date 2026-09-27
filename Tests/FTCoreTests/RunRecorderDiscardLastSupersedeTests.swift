// RunRecorder.discardLast の退避(supersede)の検証。凍結・環境エラーの再実行で捨てる直前の
// 記録は事故の証跡なので、削除ではなく superseded/ へ移す契約(RunResultsStore.supersedeScenario)
// を守る: ①scenarios/*.json → superseded/<fileBase>.<k>.json ②対応する events/*.ndjson が
// あれば同じ k で events/superseded/ へ ③2 回目の退避は1回目を上書きしない
// ④scenarios/ からは消えている ⑤対応する events が無くても落ちない

import Foundation
import XCTest
@testable import FTCore

/// この種のテストが finish() へ渡す fmSettings は値そのものを検査しないので固定の1値でよい
private let testFMSettings = FMSettingsRecord(
    heal: false, fmTextOcclusionCheck: false, screenLooksLike: true, ocrTextOcclusionCheck: true)

final class RunRecorderDiscardLastSupersedeTests: XCTestCase {
    private var repoRoot: URL!

    override func setUpWithError() throws {
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunRecorderDiscardLastSupersedeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func makeRecorder() -> RunRecorder {
        RunRecorder.begin(project: TestProject(name: "P", rootURL: repoRoot),
                          profile: nil, trigger: "cli", captureHostMetrics: false)
    }

    private func makeRecord(scenarioID: String, passed: Bool) -> ScenarioRunRecord {
        ScenarioRunRecord(
            scenarioID: scenarioID, platform: "ios", passed: passed,
            startedAt: "2026-01-01T00:00:00Z", durationMs: 10,
            steps: StepCountsRecord(total: 1, passed: passed ? 1 : 0, failed: passed ? 0 : 1))
    }

    private func writeEventsFile(_ recorder: RunRecorder, fileName: String, content: String) throws {
        let dir = recorder.runDir.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: dir.appendingPathComponent("\(fileName).ndjson"),
                          atomically: true, encoding: .utf8)
    }

    private func scenarioJSONURL(_ recorder: RunRecorder, _ fileName: String) -> URL {
        recorder.runDir.appendingPathComponent("scenarios").appendingPathComponent("\(fileName).json")
    }

    private func supersededJSONURL(_ recorder: RunRecorder, _ fileName: String, _ k: Int) -> URL {
        recorder.runDir.appendingPathComponent("superseded").appendingPathComponent("\(fileName).\(k).json")
    }

    private func eventsURL(_ recorder: RunRecorder, _ fileName: String) -> URL {
        recorder.runDir.appendingPathComponent("events").appendingPathComponent("\(fileName).ndjson")
    }

    private func supersededEventsURL(_ recorder: RunRecorder, _ fileName: String, _ k: Int) -> URL {
        recorder.runDir.appendingPathComponent("events/superseded")
            .appendingPathComponent("\(fileName).\(k).ndjson")
    }

    // MARK: - ①②④ 移動する(消さない)

    func testDiscardLastMovesJSONAndEventsToSuperseded() throws {
        let recorder = makeRecorder()
        let fileName = recorder.record(makeRecord(scenarioID: "Foo.bar", passed: false))
        XCTAssertEqual(fileName, "Foo.bar")
        try writeEventsFile(recorder, fileName: fileName, content: #"{"t":"x","stream":"host","event":{"kind":"log"}}"#)

        XCTAssertTrue(FileManager.default.fileExists(atPath: scenarioJSONURL(recorder, fileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: eventsURL(recorder, fileName).path))

        recorder.discardLast(scenarioID: "Foo.bar")

        XCTAssertFalse(FileManager.default.fileExists(atPath: scenarioJSONURL(recorder, fileName).path),
                       "scenarios/ からは消えている")
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventsURL(recorder, fileName).path))

        let supersededJSON = supersededJSONURL(recorder, fileName, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: supersededJSON.path))
        let restored = try JSONDecoder().decode(ScenarioRunRecord.self, from: Data(contentsOf: supersededJSON))
        XCTAssertEqual(restored.scenarioID, "Foo.bar")
        XCTAssertEqual(restored.passed, false)

        let supersededEvents = supersededEventsURL(recorder, fileName, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: supersededEvents.path))
        let eventsContent = try String(contentsOf: supersededEvents, encoding: .utf8)
        XCTAssertTrue(eventsContent.contains(#""kind":"log""#))
    }

    // MARK: - ⑤ 対応する events が無くても落ちない

    func testDiscardLastWithoutAMatchingEventsFileDoesNotCrash() throws {
        let recorder = makeRecorder()
        let fileName = recorder.record(makeRecord(scenarioID: "Foo.baz", passed: true))
        // events/ ファイルは作らない(ScenarioEventLog が動かなかった/dry-run 等を模す)

        recorder.discardLast(scenarioID: "Foo.baz")

        XCTAssertFalse(FileManager.default.fileExists(atPath: scenarioJSONURL(recorder, fileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: supersededJSONURL(recorder, fileName, 1).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: recorder.runDir.appendingPathComponent("events/superseded").path),
            "events/superseded/ 自体を作らない(対応する events が無ければ触らない)")
    }

    // MARK: - ③ 2 回目の退避は1回目を上書きしない

    func testSecondDiscardOfTheSameScenarioIDDoesNotOverwriteTheFirst() throws {
        let recorder = makeRecorder()

        // 1 回目: 記録 → 退避(discardLast は連番を巻き戻すので、次の record も同じ fileName になる)
        let fileName1 = recorder.record(makeRecord(scenarioID: "Foo.bar", passed: false))
        try writeEventsFile(recorder, fileName: fileName1, content: "first")
        recorder.discardLast(scenarioID: "Foo.bar")
        XCTAssertTrue(FileManager.default.fileExists(atPath: supersededJSONURL(recorder, "Foo.bar", 1).path))

        // 2 回目: 同じ scenarioID を再度記録(連番が巻き戻っているので fileName は同じ "Foo.bar")
        let fileName2 = recorder.record(makeRecord(scenarioID: "Foo.bar", passed: true))
        XCTAssertEqual(fileName1, fileName2, "discardLast は連番を巻き戻すので同じ fileName が再利用される")
        try writeEventsFile(recorder, fileName: fileName2, content: "second")
        recorder.discardLast(scenarioID: "Foo.bar")

        // 両方とも残っている(上書きされていない)
        let firstJSON = supersededJSONURL(recorder, "Foo.bar", 1)
        let secondJSON = supersededJSONURL(recorder, "Foo.bar", 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstJSON.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondJSON.path))
        let firstRecord = try JSONDecoder().decode(ScenarioRunRecord.self, from: Data(contentsOf: firstJSON))
        let secondRecord = try JSONDecoder().decode(ScenarioRunRecord.self, from: Data(contentsOf: secondJSON))
        XCTAssertEqual(firstRecord.passed, false, "1回目の内容が2回目で上書きされていない")
        XCTAssertEqual(secondRecord.passed, true)

        let firstEvents = supersededEventsURL(recorder, "Foo.bar", 1)
        let secondEvents = supersededEventsURL(recorder, "Foo.bar", 2)
        XCTAssertEqual(try String(contentsOf: firstEvents, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: secondEvents, encoding: .utf8), "second")
    }

    /// k の探索は superseded/ に既存ファイルがあっても衝突しない最小値を選ぶ
    /// (discardLast 経由でなく直接 supersedeScenario を当てて番号選択だけを見る)
    func testSupersedeScenarioSkipsExistingIndices() throws {
        let recorder = makeRecorder()
        let runDir = recorder.runDir
        let scenariosDir = runDir.appendingPathComponent("scenarios")
        try FileManager.default.createDirectory(at: scenariosDir, withIntermediateDirectories: true)
        try "{}".write(to: scenariosDir.appendingPathComponent("Foo.bar.json"), atomically: true, encoding: .utf8)

        let supersededDir = runDir.appendingPathComponent("superseded")
        try FileManager.default.createDirectory(at: supersededDir, withIntermediateDirectories: true)
        try "existing".write(to: supersededDir.appendingPathComponent("Foo.bar.1.json"),
                             atomically: true, encoding: .utf8)

        RunResultsStore.supersedeScenario(runDir: runDir, fileName: "Foo.bar")

        // 1 は既存なので触らず、2 へ書く
        XCTAssertEqual(try String(contentsOf: supersededDir.appendingPathComponent("Foo.bar.1.json"),
                                  encoding: .utf8), "existing")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: supersededDir.appendingPathComponent("Foo.bar.2.json").path))
    }
}
