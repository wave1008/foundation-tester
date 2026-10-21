// 子が scenarioFinished に載せた notApplicableReason が、結果 JSON(skipKind + skipReason・passed: true)と
// JUnit(<skipped>・failures 0)に落ちること。

import XCTest
@testable import FTCore

final class DeclaredNotApplicableRecordTests: XCTestCase {

    private func record(reason: String?) -> ScenarioRunRecord {
        var builder = ScenarioRecordBuilder(scenarioID: "T.S0010", platform: "ios", title: "t", worker: nil, engine: nil)
        var step = ScenarioEvent(kind: "step")
        step.index = 1
        step.description = "appSwitcher"
        step.status = "skipped"
        step.detail = "r"
        builder.consume(step)
        var finished = ScenarioEvent(kind: "scenarioFinished")
        finished.passed = true
        finished.notApplicableReason = reason
        builder.consume(finished)
        return builder.build(passed: true, timedOut: false, startedAt: Date(), durationMs: 10, packageRoot: nil)
    }

    func testDeclaredReasonBecomesNotApplicableWithoutFailing() throws {
        let r = record(reason: "why")
        XCTAssertEqual(r.skipKind, .notApplicable)
        XCTAssertEqual(r.skipReason, "why")
        XCTAssertTrue(r.passed)
        XCTAssertNil(r.failedSteps)
        let decoded = try JSONDecoder().decode(ScenarioRunRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded.skipReason, "why")
    }

    func testOrdinaryScenarioHasNoSkipFields() {
        let r = record(reason: nil)
        XCTAssertNil(r.skipKind)
        XCTAssertNil(r.skipReason)
    }

    func testJUnitReportsItAsSkippedNotAFailure() {
        let xml = JUnitReportWriter.xml(project: "p", records: [record(reason: "why")])
        XCTAssertTrue(xml.contains("failures=\"0\""), xml)
        XCTAssertTrue(xml.contains("skipped=\"1\""), xml)
        XCTAssertTrue(xml.contains("<skipped message=\"why\"/>"), xml)
    }
}
