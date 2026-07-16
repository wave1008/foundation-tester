import XCTest
@testable import FTCore

final class RunRecordTests: XCTestCase {

    private func stepEvent(index: Int, scene: Int, status: String, description: String = "tap",
                           detail: String? = nil, file: String? = nil, line: Int? = nil,
                           durationMs: Int? = nil) -> ScenarioEvent {
        var event = ScenarioEvent(kind: "step")
        event.index = index
        event.scene = scene
        event.status = status
        event.description = description
        event.detail = detail
        event.file = file
        event.line = line
        event.durationMs = durationMs
        return event
    }

    func testFailedScenarioCollectsStepsScenesAndFailures() throws {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.bar", platform: "ios", title: "Foo bar", worker: "ios:iPhone 16")

        var started = ScenarioEvent(kind: "sceneStarted")
        started.scene = 1
        started.sceneTitle = "Scene A"
        builder.consume(started)

        builder.consume(stepEvent(index: 0, scene: 1, status: "passed", durationMs: 100))
        builder.consume(stepEvent(
            index: 1, scene: 1, status: "failed", description: "exist #foo",
            detail: "見つかりません", file: "Scenario.swift", line: 42, durationMs: 50))

        var sceneFinished = ScenarioEvent(kind: "sceneFinished")
        sceneFinished.scene = 1
        sceneFinished.passed = false
        sceneFinished.durationMs = 250
        builder.consume(sceneFinished)

        var fix = ScenarioEvent(kind: "fixSuggestion")
        fix.scene = 1
        fix.file = "Scenario.swift"
        fix.line = 42
        fix.oldSelector = "#foo"
        fix.newSelector = "#foo2"
        builder.consume(fix)

        var finished = ScenarioEvent(kind: "scenarioFinished")
        finished.passed = false
        finished.reportPath = "/repo/root/Projects/SampleApp/reports/foo.json"
        builder.consume(finished)

        let record = builder.build(
            passed: false, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 900, packageRoot: URL(fileURLWithPath: "/repo/root"))

        XCTAssertEqual(record.scenarioID, "Foo.bar")
        XCTAssertEqual(record.platform, "ios")
        XCTAssertEqual(record.worker, "ios:iPhone 16")
        XCTAssertFalse(record.passed)
        XCTAssertEqual(record.durationMs, 900)

        XCTAssertEqual(record.scenes.count, 1)
        XCTAssertEqual(record.scenes[0].scene, 1)
        XCTAssertEqual(record.scenes[0].title, "Scene A")
        XCTAssertFalse(record.scenes[0].passed)
        XCTAssertEqual(record.scenes[0].durationMs, 250, "sceneFinished の durationMs を優先")

        XCTAssertEqual(record.steps.total, 2)
        XCTAssertEqual(record.steps.passed, 1)
        XCTAssertEqual(record.steps.failed, 1)

        let failedSteps = try XCTUnwrap(record.failedSteps)
        XCTAssertEqual(failedSteps.count, 1)
        XCTAssertEqual(failedSteps[0].index, 1)
        XCTAssertEqual(failedSteps[0].scene, 1)
        XCTAssertEqual(failedSteps[0].sceneTitle, "Scene A")
        XCTAssertEqual(failedSteps[0].description, "exist #foo")
        XCTAssertEqual(failedSteps[0].detail, "見つかりません")
        XCTAssertEqual(failedSteps[0].file, "Scenario.swift")
        XCTAssertEqual(failedSteps[0].line, 42)

        let fixSuggestions = try XCTUnwrap(record.fixSuggestions)
        XCTAssertEqual(fixSuggestions.count, 1)
        XCTAssertEqual(fixSuggestions[0].oldSelector, "#foo")
        XCTAssertEqual(fixSuggestions[0].newSelector, "#foo2")

        XCTAssertEqual(record.reportPath, "Projects/SampleApp/reports/foo.json", "packageRoot の prefix を剥がして相対化")
    }

    func testPassedScenarioHasNilFailureFields() {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.baz", platform: "android", title: nil, worker: nil)

        var started = ScenarioEvent(kind: "sceneStarted")
        started.scene = 1
        started.sceneTitle = "Scene A"
        builder.consume(started)
        builder.consume(stepEvent(index: 0, scene: 1, status: "passed", durationMs: 10))

        var sceneFinished = ScenarioEvent(kind: "sceneFinished")
        sceneFinished.scene = 1
        sceneFinished.passed = true
        builder.consume(sceneFinished)

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 50, packageRoot: nil)

        XCTAssertTrue(record.passed)
        XCTAssertNil(record.failedSteps)
        XCTAssertNil(record.fixSuggestions)
        XCTAssertEqual(record.scenes[0].durationMs, 10, "sceneFinished に durationMs が無ければ step 合計を使う")
    }

    func testReportPathKeptAsIsWhenPrefixMismatches() {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.qux", platform: "ios", title: nil, worker: nil)
        var finished = ScenarioEvent(kind: "scenarioFinished")
        finished.reportPath = "/elsewhere/reports/foo.json"
        builder.consume(finished)

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 0, packageRoot: URL(fileURLWithPath: "/repo/root"))

        XCTAssertEqual(record.reportPath, "/elsewhere/reports/foo.json")
    }

    func testSceneWithoutAnyDurationEventsIsNil() {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.quux", platform: "ios", title: nil, worker: nil)
        var sceneFinished = ScenarioEvent(kind: "sceneFinished")
        sceneFinished.scene = 1
        sceneFinished.passed = true
        builder.consume(sceneFinished)

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 0, packageRoot: nil)

        XCTAssertNil(record.scenes[0].durationMs)
    }
}
