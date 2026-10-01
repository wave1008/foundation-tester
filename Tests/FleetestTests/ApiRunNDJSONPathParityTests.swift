// `fleetest api run` の逐次経路(シナリオ実行プロセスの ScenarioEvent をそのまま流す)と
// 並列(--profile)経路(RunEvent から NDJSON を再構築する)が、step / scenarioFinished に
// 同じ欄の集合を出すことの固定。再構築側が欄を落とすと、拡張は欠けた欄を nil で読むので
// 気付けず、片方の経路の run だけ command / failureKind / notes / guarded / appCrash が消える。
// 機械分担の runFinished.testSeconds(単機と同じ定義)もここで固定する。

import XCTest
import FTCore
@testable import FTCore
@testable import fleetest

final class ApiRunNDJSONPathParityTests: XCTestCase {

    private let scenarioID = "ログインテスト.S0010"
    private let workerLabel = "ios:8123"
    private var item: ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: scenarioID, title: "t", app: "A", platform: nil, deleted: false))
    }

    private func object(_ line: String) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary)
    }

    /// ScenarioEvent のうち step に載る欄以外(step の fixture が nil のままでよい欄)。
    /// 新しい欄を ScenarioEvent に足すと、ここに入れるか fixture へ足すかを選ばされる
    private let nonStepFields: Set<String> = [
        "worker", "title", "file", "line", "oldSelector", "newSelector", "passed", "reportPath",
        "message", "fm", "requestID", "installPath", "appCrash",
    ]

    private func fullStepEvent() -> ScenarioEvent {
        var e = ScenarioEvent(kind: "step")
        e.scenario = scenarioID
        e.scene = 2; e.sceneTitle = "ログイン"; e.section = "action"
        e.index = 7; e.description = "tap \"ログイン\""; e.status = "failed"; e.detail = "not found"
        e.durationMs = 120; e.snapshotMs = 30; e.actionMs = 40; e.waitMs = 10
        e.scheduleDelayMs = 1; e.cpuMs = 2; e.ioBlockedMs = 3; e.stallMs = 4; e.poolStallMs = 5
        e.guardMs = 6; e.ocrMs = 7
        e.notes = ["system-alert-present"]
        e.at = "2026-10-02T10:00:00.000Z"
        e.command = "tap"
        e.failureKind = StepFailureKind.driverUnreachable.rawValue
        e.guarded = true
        return e
    }

    func testStepFixtureCoversEveryStepField() {
        let e = fullStepEvent()
        for child in Mirror(reflecting: e).children {
            guard let label = child.label else { continue }
            let m = Mirror(reflecting: child.value)
            let isNil = m.displayStyle == .optional && m.children.isEmpty
            if isNil { XCTAssertTrue(nonStepFields.contains(label), "fixture に \(label) が無い(step の欄なら足す・違うなら nonStepFields へ)") }
        }
    }

    func testParallelStepCarriesTheSameFieldsAsSequential() throws {
        let sequential = try object(fullStepEvent().encodedLine())
        let result = ScenarioRunner.stepResult(from: fullStepEvent())
        let url = item.url
        let lines = ApiRunCommand.ndjsonLines(
            for: .step(worker: workerLabel, flowURL: url, result: result),
            itemByURL: [url: item], workerID: WorkerIDMap([]))
        XCTAssertEqual(lines.count, 1)
        let parallel = NSMutableDictionary(dictionary: try object(try XCTUnwrap(lines.first)))
        XCTAssertEqual(parallel["worker"] as? String, workerLabel)
        parallel.removeObject(forKey: "worker")   // 並列経路だけが付ける欄
        XCTAssertEqual(Set(parallel.allKeys as! [String]), Set(sequential.allKeys as! [String]))
        XCTAssertEqual(parallel, sequential)
    }

    func testParallelScenarioFinishedCarriesAppCrashAndFM() throws {
        let crash = AppCrashRecord(evidence: .crashReport, path: "/tmp/a.ips", summary: "EXC_BAD_ACCESS")
        let fm = FMUsageRecord(calls: 1, failures: 0, totalMs: 10, p50Ms: 10, maxMs: 10, byKind: [:])
        var seq = ScenarioEvent(kind: "scenarioFinished")
        seq.scenario = scenarioID; seq.passed = false; seq.reportPath = "/tmp/r.json"
        seq.fm = fm; seq.appCrash = crash
        let url = item.url
        let lines = ApiRunCommand.ndjsonLines(
            for: .flowFinished(worker: workerLabel, flowURL: url, passed: false,
                               reportURL: URL(fileURLWithPath: "/tmp/r.json"), fm: fm, appCrash: crash),
            itemByURL: [url: item], workerID: WorkerIDMap([]))
        let parallel = NSMutableDictionary(dictionary: try object(try XCTUnwrap(lines.first)))
        parallel.removeObject(forKey: "worker")
        XCTAssertEqual(parallel, try object(seq.encodedLine()))
    }

    /// RunOrchestrator が子の scenarioFinished の appCrash を RunEvent へ渡していること
    /// (ScenarioHost 越しなので単体では通せない = 型の効かない継ぎ目のソース走査)
    func testRunOrchestratorForwardsAppCrash() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/RunOrchestrator.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("appCrash = event.appCrash"))
        XCTAssertTrue(source.contains("fm: fmUsage, appCrash: appCrash"))
    }

    // MARK: - 機械分担の testSeconds

    private func at(_ s: Double) -> Date { Date(timeIntervalSinceReferenceDate: s) }

    /// 単機の testSeconds = 最初のシナリオ開始〜最後の完了(ScenarioTimingTracker)。
    /// 子の起動がずれても区間全体を測る(子ごとの testSeconds の最大値では 105 でなく 100 になる)
    func testFanoutTestSecondsSpansFirstStartToLastFinish() {
        var mux = MachineFanoutMultiplexer(groupMachines: [nil, "M1Max"])
        XCTAssertNil(mux.testSeconds)
        _ = mux.ingest(childIndex: 0, line: #"{"kind":"scenarioStarted","scenario":"A.S1"}"#, now: at(1000))
        _ = mux.ingest(childIndex: 0, line: #"{"kind":"scenarioFinished","scenario":"A.S1","passed":true}"#, now: at(1100))
        _ = mux.ingest(childIndex: 1, line: #"{"kind":"scenarioStarted","scenario":"B.S1"}"#, now: at(1005))
        _ = mux.ingest(childIndex: 1, line: #"{"kind":"scenarioFinished","scenario":"B.S1","passed":true}"#, now: at(1105))
        XCTAssertEqual(try XCTUnwrap(mux.testSeconds), 105, accuracy: 0.001)
    }

    func testFanoutTestSecondsIgnoresSynthesizedFailures() {
        var mux = MachineFanoutMultiplexer(groupMachines: [nil], assignedScenarioIDs: [["A.S1"]])
        _ = mux.childExited(0, exitCode: 1)
        XCTAssertNil(mux.testSeconds, "走っていないシナリオの合成 failed は時間に数えない")
    }
}
