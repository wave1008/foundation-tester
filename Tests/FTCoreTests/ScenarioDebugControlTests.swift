// checkpoint はブロックするため、DSL 実行スレッド相当を別スレッドで模して検証する
import XCTest
@testable import FTCore

final class ScenarioDebugControlTests: XCTestCase {

    /// checkpoint を別スレッドで走らせ、onPause の通知と結果を受け取るヘルパー
    private final class CheckpointRun: @unchecked Sendable {
        let pausedExpectation: XCTestExpectation
        let finishedExpectation: XCTestExpectation
        private(set) var result: ScenarioDebugControl.CheckpointResult?
        private(set) var didPause = false

        init(_ testCase: XCTestCase, control: ScenarioDebugControl,
             file: String, line: Int) {
            pausedExpectation = testCase.expectation(description: "paused \(file):\(line)")
            pausedExpectation.isInverted = false
            finishedExpectation = testCase.expectation(description: "finished \(file):\(line)")
            Thread.detachNewThread { [self] in
                result = control.checkpoint(file: file, line: line) {
                    didPause = true
                    pausedExpectation.fulfill()
                }
                finishedExpectation.fulfill()
            }
        }
    }

    func testParseLocation() {
        XCTAssertNil(ScenarioDebugControl.parseLocation("noline"))
        XCTAssertNil(ScenarioDebugControl.parseLocation(":12"))
        XCTAssertNil(ScenarioDebugControl.parseLocation("a.swift:0"))
        let parsed = ScenarioDebugControl.parseLocation(
            "Projects/SampleApp/Scenarios/ログイン画面.swift:18")
        XCTAssertEqual(parsed?.file, "Projects/SampleApp/Scenarios/ログイン画面.swift")
        XCTAssertEqual(parsed?.line, 18)
    }

    func testNoBreakpointProceedsWithoutPause() {
        let control = ScenarioDebugControl()
        var paused = false
        let result = control.checkpoint(file: "a.swift", line: 10) { paused = true }
        XCTAssertEqual(result, .proceed)
        XCTAssertFalse(paused)
    }

    func testBreakpointPausesAndContinues() {
        let control = ScenarioDebugControl(breakpoints: ["Scenarios/a.swift:10"])

        // 非該当行は素通り
        var paused = false
        XCTAssertEqual(control.checkpoint(file: "Scenarios/a.swift", line: 9) { paused = true },
                       .proceed)
        XCTAssertFalse(paused)

        let run = CheckpointRun(self, control: control, file: "Scenarios/a.swift", line: 10)
        wait(for: [run.pausedExpectation], timeout: 5)
        control.apply(line: #"{"cmd":"continue"}"#)
        wait(for: [run.finishedExpectation], timeout: 5)
        XCTAssertEqual(run.result, .proceed)

        let second = CheckpointRun(self, control: control, file: "Scenarios/a.swift", line: 10)
        wait(for: [second.pausedExpectation], timeout: 5)
        control.apply(line: #"{"cmd":"continue"}"#)
        wait(for: [second.finishedExpectation], timeout: 5)
    }

    func testBreakpointMatchesPathSuffix() {
        // ホスト側が絶対パス・ランナー側が相対パス(またはその逆)でも一致する
        let control = ScenarioDebugControl(breakpoints: ["/repo/Scenarios/a.swift:10"])
        let run = CheckpointRun(self, control: control, file: "Scenarios/a.swift", line: 10)
        wait(for: [run.pausedExpectation], timeout: 5)
        control.apply(line: #"{"cmd":"continue"}"#)
        wait(for: [run.finishedExpectation], timeout: 5)
    }

    func testPauseOnStartThenStepOver() {
        let control = ScenarioDebugControl(pauseOnStart: true)

        let first = CheckpointRun(self, control: control, file: "a.swift", line: 1)
        wait(for: [first.pausedExpectation], timeout: 5)
        control.apply(line: #"{"cmd":"step"}"#)
        wait(for: [first.finishedExpectation], timeout: 5)
        XCTAssertEqual(first.result, .proceed)

        // step 後は次のステップでも停止する(ブレークポイント無しでも)
        let second = CheckpointRun(self, control: control, file: "a.swift", line: 2)
        wait(for: [second.pausedExpectation], timeout: 5)
        control.apply(line: #"{"cmd":"continue"}"#)
        wait(for: [second.finishedExpectation], timeout: 5)

        var paused = false
        XCTAssertEqual(control.checkpoint(file: "a.swift", line: 3) { paused = true }, .proceed)
        XCTAssertFalse(paused)
    }

    func testPauseCommandStopsAtNextStep() {
        let control = ScenarioDebugControl()
        control.apply(line: #"{"cmd":"pause"}"#)
        let run = CheckpointRun(self, control: control, file: "a.swift", line: 5)
        wait(for: [run.pausedExpectation], timeout: 5)
        control.apply(line: #"{"cmd":"continue"}"#)
        wait(for: [run.finishedExpectation], timeout: 5)
    }

    func testStopWhilePausedAborts() {
        let control = ScenarioDebugControl(pauseOnStart: true)
        let run = CheckpointRun(self, control: control, file: "a.swift", line: 1)
        wait(for: [run.pausedExpectation], timeout: 5)
        control.apply(line: #"{"cmd":"stop"}"#)
        wait(for: [run.finishedExpectation], timeout: 5)
        XCTAssertEqual(run.result, .abort)
    }

    func testStopWhileRunningAbortsNextCheckpoint() {
        let control = ScenarioDebugControl()
        control.apply(line: #"{"cmd":"stop"}"#)
        var paused = false
        let result = control.checkpoint(file: "a.swift", line: 1) { paused = true }
        XCTAssertEqual(result, .abort)
        XCTAssertFalse(paused)
    }

    func testBreakpointsReplacedByCommand() {
        let control = ScenarioDebugControl(breakpoints: ["a.swift:10"])
        control.apply(line: #"{"cmd":"breakpoints","locations":["b.swift:20"]}"#)

        // 旧ブレークポイントは外れ、新しい行で停止する
        var paused = false
        XCTAssertEqual(control.checkpoint(file: "a.swift", line: 10) { paused = true }, .proceed)
        XCTAssertFalse(paused)

        let run = CheckpointRun(self, control: control, file: "b.swift", line: 20)
        wait(for: [run.pausedExpectation], timeout: 5)
        control.apply(line: #"{"cmd":"continue"}"#)
        wait(for: [run.finishedExpectation], timeout: 5)
    }

    func testMalformedCommandsIgnored() {
        let control = ScenarioDebugControl()
        control.apply(line: "")
        control.apply(line: "not json")
        control.apply(line: #"{"nocmd":1}"#)
        control.apply(line: #"{"cmd":"unknown"}"#)
        var paused = false
        XCTAssertEqual(control.checkpoint(file: "a.swift", line: 1) { paused = true }, .proceed)
        XCTAssertFalse(paused)
    }
}
