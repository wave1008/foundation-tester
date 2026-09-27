// EventLogFormat.format(_:) の境界。events/*.ndjson の1行が既定でどう見えるかを
// リテラルで固定する(fleetest results log の唯一の整形経路)。
// セレクタの `#id` と JSON のクォートが両方出るので、リテラルは二重ハッシュの raw string(`##"…"##`)で
// 統一する(単ハッシュだと `"#` の並びが raw string の終端と衝突する)。

import XCTest
@testable import FTCore

final class EventLogFormatTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private func line(_ eventJSON: String, t: String = "2026-09-28T00:14:03.123Z",
                      stream: String = "stdout") -> String {
        ##"{"t":"\##(t)","stream":"\##(stream)","event":\##(eventJSON)}"##
    }

    // MARK: - text 行

    func testTextLineOnStderrShowsStreamTag() {
        let raw = ##"{"t":"2026-09-28T00:14:03.123Z","stream":"stderr","text":"boom"}"##
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc), ["00:14:03.123 [stderr] boom"])
    }

    func testTextLineOnHostStreamShowsStreamTag() {
        let raw = ##"{"t":"2026-09-28T00:14:03.123Z","stream":"host","text":"watchdog extended"}"##
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc), ["00:14:03.123 [host] watchdog extended"])
    }

    // MARK: - 壊れた行

    func testMalformedJSONIsPassedThroughNotSkipped() {
        XCTAssertEqual(EventLogFormat.format("not json at all", timeZone: utc), ["?? not json at all"])
    }

    func testEmptyLineProducesNoOutput() {
        XCTAssertEqual(EventLogFormat.format("", timeZone: utc), [])
        XCTAssertEqual(EventLogFormat.format("   ", timeZone: utc), [])
    }

    func testLineWithNeitherEventNorTextIsPassedThrough() {
        let raw = ##"{"t":"2026-09-28T00:14:03.123Z","stream":"stdout"}"##
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc), ["?? \(raw)"])
    }

    func testMissingTimestampFallsBackToPlaceholder() {
        let raw = ##"{"stream":"stdout","event":{"kind":"log","message":"hi"}}"##
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc), ["??:??:??.??? hi"])
    }

    // MARK: - step

    func testPassedStepShowsCheckAndDuration() {
        let raw = line(##"{"kind":"step","index":1,"section":"action","description":"tap \"#login\"","status":"passed","durationMs":820}"##)
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc),
                       [##"00:14:03.123     ✅ 1. [action] tap "#login" (820ms)"##])
    }

    func testFailedStepShowsCrossAndDetailOnSecondLine() {
        let raw = line(##"{"kind":"step","index":3,"section":"expectation","description":"exist \"#ok\"","status":"failed","detail":"not found","durationMs":50}"##)
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc),
                       [##"00:14:03.123     ❌ 3. [expectation] exist "#ok" (50ms)"##,
                        "00:14:03.123        not found"])
    }

    func testHealedStepShowsWrenchAndDetail() {
        let raw = line(##"{"kind":"step","index":2,"description":"tap \"#ok\"","status":"healed","detail":"resolved via #ok_v2"}"##)
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc),
                       [##"00:14:03.123     🔧 2. tap "#ok" → resolved via #ok_v2"##])
    }

    func testStepWithoutDurationOmitsDurationSuffix() {
        let raw = line(##"{"kind":"step","index":1,"description":"launch app","status":"passed"}"##)
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc), ["00:14:03.123     ✅ 1. launch app"])
    }

    // MARK: - scenario / scene

    func testScenarioStartedShowsIDAndTitle() {
        let raw = line(##"{"kind":"scenarioStarted","scenario":"Login.成功する","title":"ログイン成功"}"##)
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc), ["00:14:03.123 ▶ Login.成功する — ログイン成功"])
    }

    func testSceneStartedShowsNumberAndTitle() {
        let raw = line(##"{"kind":"sceneStarted","scene":2,"sceneTitle":"ホーム画面"}"##)
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc), ["00:14:03.123   scene 2: ホーム画面"])
    }

    func testScenarioFinishedPassedShowsReportPath() {
        let raw = line(##"{"kind":"scenarioFinished","passed":true,"reportPath":"/tmp/r.md"}"##)
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc),
                       ["00:14:03.123   → ✅ passed", "00:14:03.123   → report: /tmp/r.md"])
    }

    func testScenarioFinishedFailedWithoutReportPath() {
        let raw = line(##"{"kind":"scenarioFinished","passed":false}"##)
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc), ["00:14:03.123   → ❌ failed"])
    }

    // MARK: - log / deviceFrozen

    func testLogEventShowsMessageOnly() {
        let raw = line(##"{"kind":"log","message":"⚠️ scene 2 is duplicated"}"##)
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc), ["00:14:03.123 ⚠️ scene 2 is duplicated"])
    }

    func testDeviceFrozenShowsScenario() {
        let raw = line(##"{"kind":"deviceFrozen","scenario":"Login.成功する"}"##)
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc),
                       ["00:14:03.123   🥶 device frozen (Login.成功する)"])
    }

    // MARK: - 未知の kind

    func testUnknownKindDumpsSortedFields() {
        let raw = line(##"{"kind":"somethingNew","zeta":"z","alpha":1,"flag":true}"##)
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc),
                       ["00:14:03.123   [somethingNew] alpha=1 flag=true zeta=z"])
    }

    func testUnknownKindWithNoOtherFields() {
        let raw = line(##"{"kind":"pingOnly"}"##)
        XCTAssertEqual(EventLogFormat.format(raw, timeZone: utc), ["00:14:03.123   [pingOnly]"])
    }
}
