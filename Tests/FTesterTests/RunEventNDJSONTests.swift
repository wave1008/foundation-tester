// `ftester api run --profile`(並列実行)の RunEvent → NDJSON 行の写像。
//
// これは VSCode 拡張との配線契約そのもの: 親プロセスは進捗を RunEvent(Codable ではない)で
// 受け、ここで NDJSON を**再構築**して stdout へ流す。対向は vscode-ftester/src/model.ts と
// runReducer.ts。kind 名・フィールド名を落とすと Test Explorer の項目が動かない/結果が
// 反映されないという形で壊れるが、シナリオ自体は成功するため E2E でも緑のまま通る
// (実際に「fm を落としてモニターの FM グラフが 0 のまま」の実害がある)。

import XCTest
import FTCore
@testable import ftester

final class RunEventNDJSONTests: XCTestCase {

    // MARK: - fixtures

    private let workerLabel = "ios:8123"
    /// 空マップ。id(for:) は未登録ラベルをそのまま返すので、worker フィールドはラベルと一致する
    /// (ラベル → "platform:論理名" の写像は WorkerIDMap 側の責務で、ここでは扱わない)。
    private let workerID = WorkerIDMap([])

    private let scenarioID = "ログインテスト.S0010"
    private var item: ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: scenarioID, title: "ログインできる",
                                           app: "SampleApp", platform: nil, deleted: false))
    }
    private var flowURL: URL { item.url }
    private var itemByURL: [URL: ScenarioRunItem] { [flowURL: item] }

    private func lines(_ event: RunEvent) -> [String] {
        ApiRunCommand.ndjsonLines(for: event, itemByURL: itemByURL, workerID: workerID)
    }

    /// 1行だけ出ることを確かめ、JSON オブジェクトとして返す。
    private func single(_ event: RunEvent, file: StaticString = #filePath,
                        line: UInt = #line) throws -> [String: Any] {
        let out = lines(event)
        XCTAssertEqual(out.count, 1, "1行だけ出るべきです: \(out)", file: file, line: line)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(out.first).utf8)) as? [String: Any],
            file: file, line: line)
        return object
    }

    // MARK: - 出力しないイベント

    func testEventsHandledElsewhereEmitNothing() {
        // runStarted/runFinished は呼び出し側が emit 済み。flowHealed は旧互換、flowPaused は
        // デバッグ専用でこの経路に来ない。ここで行を出すと二重計上になる
        XCTAssertEqual(lines(.runStarted(total: 3, workerLabels: [workerLabel])), [])
        XCTAssertEqual(lines(.runFinished(passed: 3, failed: 0)), [])
        XCTAssertEqual(lines(.workerReady(worker: workerLabel)), [])
        XCTAssertEqual(lines(.flowHealed(worker: workerLabel, flowURL: flowURL)), [])
        XCTAssertEqual(lines(.flowPaused(worker: workerLabel, flowURL: flowURL, index: 1,
                                         description: "tap", file: nil, line: nil)), [])
    }

    // MARK: - シナリオ・scene のライフサイクル

    func testFlowStartedCarriesTitleFromRunItem() throws {
        let event = try single(.flowStarted(worker: workerLabel, flowURL: flowURL,
                                            flowName: scenarioID, isDirty: false))
        XCTAssertEqual(event["kind"] as? String, "scenarioStarted")
        XCTAssertEqual(event["worker"] as? String, workerLabel)
        XCTAssertEqual(event["scenario"] as? String, scenarioID)
        XCTAssertEqual(event["title"] as? String, "ログインできる")
    }

    func testFlowFinishedCarriesPassedReportPathAndFM() throws {
        let fm = FMUsageRecord(calls: 4, failures: 1, totalMs: 4200, p50Ms: 900, maxMs: 1800, byKind: [:])
        let event = try single(.flowFinished(
            worker: workerLabel, flowURL: flowURL, passed: true, triage: nil,
            reportURL: URL(fileURLWithPath: "/tmp/report.json"), fm: fm))

        XCTAssertEqual(event["kind"] as? String, "scenarioFinished")
        XCTAssertEqual(event["passed"] as? Bool, true)
        XCTAssertEqual(event["reportPath"] as? String, "/tmp/report.json")
        // fm を落とすとモニターの FM グラフが 0 のままになる(実害あり)
        let fmObject = try XCTUnwrap(event["fm"] as? [String: Any], "fm が欠けています: \(event)")
        XCTAssertEqual(fmObject["calls"] as? Int, 4)
    }

    func testSceneStartedAndFinished() throws {
        let started = try single(.sceneStarted(worker: workerLabel, flowURL: flowURL,
                                               scene: 2, sceneTitle: "ログイン"))
        XCTAssertEqual(started["kind"] as? String, "sceneStarted")
        XCTAssertEqual(started["scene"] as? Int, 2)
        XCTAssertEqual(started["sceneTitle"] as? String, "ログイン")

        let finished = try single(.sceneFinished(worker: workerLabel, flowURL: flowURL,
                                                 scene: 2, sceneTitle: "ログイン", passed: false))
        XCTAssertEqual(finished["kind"] as? String, "sceneFinished")
        XCTAssertEqual(finished["passed"] as? Bool, false)
    }

    // MARK: - step

    private func stepEvent(_ result: StepResult) throws -> [String: Any] {
        try single(.step(worker: workerLabel, flowURL: flowURL, result: result))
    }

    func testSyntheticStepIsDropped() {
        // fixSuggestion に伴う合成行は次の .fixSuggestion で出すので、ここで出すと二重になる
        let result = StepResult(index: 5, description: "💡 修正提案", status: .passed, synthetic: true)
        XCTAssertEqual(lines(.step(worker: workerLabel, flowURL: flowURL, result: result)), [])
    }

    func testStepIndexZeroBecomesLogLine() throws {
        // index 0 は log イベント由来の情報行の目印(ScenarioRunner.runOne)
        let event = try stepEvent(StepResult(index: 0, description: "ユーザーの print", status: .passed))
        XCTAssertEqual(event["kind"] as? String, "log")
        XCTAssertEqual(event["message"] as? String, "ユーザーの print")
        XCTAssertNil(event["status"], "log 行に status を載せない")
    }

    func testStepStatusMapping() throws {
        var locator = FlowLocator()
        locator.id = "login_button"

        let cases: [(StepResult.Status, String, String?)] = [
            (.passed, "passed", nil),
            (.passedViaFallback(locator), "passedViaFallback", locator.summary),
            (.healed(locator), "healed", locator.summary),
            (.failed("要素が見つかりません"), "failed", "要素が見つかりません"),
            (.skipped("platform 不一致"), "skipped", "platform 不一致"),
        ]
        for (status, expected, detail) in cases {
            let event = try stepEvent(StepResult(index: 3, description: "tap", status: status))
            XCTAssertEqual(event["kind"] as? String, "step")
            XCTAssertEqual(event["status"] as? String, expected)
            XCTAssertEqual(event["detail"] as? String, detail, "status=\(expected) の detail")
        }
    }

    func testStepCarriesTimingBreakdownAndPosition() throws {
        let timing = StepTiming(durationMs: 444, snapshotMs: 9, actionMs: 380, waitMs: 55)
        let event = try stepEvent(StepResult(
            index: 7, description: "tap \"#login\"", status: .passed,
            scene: 1, sceneTitle: "ログイン", section: "action",
            timing: timing, at: "2026-07-29T10:20:30.123Z"))

        XCTAssertEqual(event["index"] as? Int, 7)
        XCTAssertEqual(event["scene"] as? Int, 1)
        XCTAssertEqual(event["sceneTitle"] as? String, "ログイン")
        XCTAssertEqual(event["section"] as? String, "action")
        XCTAssertEqual(event["description"] as? String, "tap \"#login\"")
        // 時間内訳はレポート・性能計測の入力(docs/performance-tuning.md §4)
        XCTAssertEqual(event["durationMs"] as? Int, 444)
        XCTAssertEqual(event["snapshotMs"] as? Int, 9)
        XCTAssertEqual(event["actionMs"] as? Int, 380)
        XCTAssertEqual(event["waitMs"] as? Int, 55)
        XCTAssertEqual(event["at"] as? String, "2026-07-29T10:20:30.123Z")
    }

    // MARK: - ワーカーの離脱・進行・振り直し

    func testWorkerFailedBecomesLogLineNamingTheWorker() throws {
        let event = try single(.workerFailed(worker: workerLabel, message: "接続できません"))
        XCTAssertEqual(event["kind"] as? String, "log")
        let message = try XCTUnwrap(event["message"] as? String)
        XCTAssertTrue(message.contains(workerLabel), "ワーカー名を含めること: \(message)")
        XCTAssertTrue(message.contains("接続できません"), "理由を含めること: \(message)")
    }

    func testWorkerLogPassesMessageThrough() throws {
        let event = try single(.workerLog(worker: workerLabel, message: "ブリッジを再供給しています"))
        XCTAssertEqual(event["kind"] as? String, "log")
        XCTAssertEqual(event["message"] as? String, "ブリッジを再供給しています")
    }

    func testFlowRequeuedEmitsScenarioRequeuedContract() throws {
        // 契約: vscode-ftester/src/model.ts ScenarioRequeuedEvent / runReducer の "requeued"。
        // Test Explorer は該当項目を「待機中」アイコンへ戻す
        let event = try single(.flowRequeued(worker: workerLabel, flowURL: flowURL,
                                             reason: "ブリッジ無応答", attempt: 2, limit: 3))
        XCTAssertEqual(event["kind"] as? String, "scenarioRequeued")
        XCTAssertEqual(event["scenario"] as? String, scenarioID)
        XCTAssertEqual(event["worker"] as? String, workerLabel)
        XCTAssertEqual(event["reason"] as? String, "ブリッジ無応答")
        XCTAssertEqual(event["attempt"] as? Int, 2)
        XCTAssertEqual(event["limit"] as? Int, 3)
    }

    func testFlowRequeuedForUnknownScenarioEmitsNothing() {
        // 対応する run item が無ければ「どの項目を待機中に戻すか」が決まらないので出さない
        let unknown = ScenarioRunItem.url(for: "知らないシナリオ")
        XCTAssertEqual(lines(.flowRequeued(worker: workerLabel, flowURL: unknown,
                                           reason: "x", attempt: 1, limit: 3)), [])
    }

    // MARK: - fixSuggestion

    func testFixSuggestionCarriesSelectorsAndSourcePosition() throws {
        let event = try single(.fixSuggestion(
            worker: workerLabel, flowURL: flowURL, scenarioID: scenarioID,
            command: ##"tap "#old""##, file: "/repo/S0010.swift", line: 42,
            oldSelector: "#old", newSelector: "#new", message: "id が変わっています"))

        XCTAssertEqual(event["kind"] as? String, "fixSuggestion")
        XCTAssertEqual(event["scenario"] as? String, scenarioID)
        XCTAssertEqual(event["description"] as? String, ##"tap "#old""##)
        XCTAssertEqual(event["file"] as? String, "/repo/S0010.swift")
        XCTAssertEqual(event["line"] as? Int, 42)
        XCTAssertEqual(event["oldSelector"] as? String, "#old")
        XCTAssertEqual(event["newSelector"] as? String, "#new")
        XCTAssertEqual(event["detail"] as? String, "id が変わっています")
    }

    // MARK: - flowSkipped

    func testFlowSkippedSynthesizesFullFailureSequence() throws {
        // 担当ワーカー不在のシナリオ。runFinished の failed に計上させるため、開始〜失敗〜終了の
        // 3行を合成する(1行でも欠けると Test Explorer の項目が実行中のまま残る)
        let out = lines(.flowSkipped(flowURL: flowURL, reason: "ワーカーが全滅しました"))
        XCTAssertEqual(out.count, 3)

        let events = try out.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(events.map { $0["kind"] as? String },
                       ["scenarioStarted", "step", "scenarioFinished"])
        XCTAssertEqual(events[1]["status"] as? String, "failed")
        XCTAssertEqual(events[1]["detail"] as? String, "ワーカーが全滅しました")
        XCTAssertEqual(events[2]["passed"] as? Bool, false)
        // 担当ワーカーが居ないので worker は付けない
        for event in events {
            XCTAssertNil(event["worker"], "flowSkipped に worker を付けない: \(event)")
        }
    }
}
