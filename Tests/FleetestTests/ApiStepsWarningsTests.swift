// `fleetest api steps` は kind == "log" イベントを丸ごと捨てていたため、dry-run が出す警告
// (空の expectation ブロック・台帳に無い #id 等。FTRuntime.swift の
// `emit(.log("⚠️ " + message))`)が VSCode 拡張のステップ表に一切届かなかった。
// ApiSteps.warnings は「⚠️ 接頭辞の log だけを拾う」判別だけを切り出した純粋関数で、
// ScenarioEvent の値を組み立てるだけでデバイス・ビルドに触らず固定できる。
import XCTest
import FTCore

@testable import fleetest

final class ApiStepsWarningsTests: XCTestCase {

    private func log(_ message: String) -> ScenarioEvent {
        var event = ScenarioEvent(kind: "log")
        event.message = message
        return event
    }

    func testPicksUpOnlyExclamationPrefixedLogLines() {
        let warning = log("⚠️ the expectation block of scene 1 (\"login\") contains no assertions"
            + " (it checks nothing). Add exist / textIs / thisIs etc.")
        let info = log("ℹ️ launched com.example.app")
        let userPrint = log("hello from print()")
        var step = ScenarioEvent(kind: "step")
        step.description = "tap \"#login_btn\""
        var sceneStarted = ScenarioEvent(kind: "sceneStarted")
        sceneStarted.scene = 1

        let warnings = ApiSteps.warnings(from: [warning, info, userPrint, step, sceneStarted])

        XCTAssertEqual(warnings, [warning.message!])
    }

    func testReturnsEmptyWhenNoWarnings() {
        var step = ScenarioEvent(kind: "step")
        step.description = "tap \"#login_btn\""
        XCTAssertEqual(ApiSteps.warnings(from: [step, log("ℹ️ info only")]), [])
    }

    func testPreservesOrderAndDuplicates() {
        let first = log("⚠️ first")
        let second = log("⚠️ second")
        XCTAssertEqual(ApiSteps.warnings(from: [first, second, first]),
                       [first.message!, second.message!, first.message!])
    }
}
