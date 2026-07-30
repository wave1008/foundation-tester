import XCTest

@testable import FTDSL
import FTCore

/// Flow → Swift DSL コードの生成(`ftester api gen-scenario` が使う)。
/// **生成物は利用者がそのまま実行するコード**なので、秒引数が Double 化された後も
/// `duration: 1` / `timeout: 1.2` の形で出る(`1.0` や `1.2000000000000002` にしない)ことを固定する。
final class ScenarioCodeGenTests: XCTestCase {

    private func render(_ steps: [FlowStep]) -> String {
        ScenarioCodeGen.render(
            flow: Flow(name: "生成", app: "com.example.app", goal: nil,
                       generatedBy: "test", steps: steps),
            className: "生成されたシナリオ", generatedBy: "test")
    }

    func testTapEmitsFractionalHoldSecondsAndOmitsItWhenAbsent() {
        let fractional = render([
            FlowStep(action: "tap", locator: FlowLocator(id: "btn"), duration: 1.5),
        ])
        XCTAssertTrue(fractional.contains("tap(\"#btn\", holdSeconds: 1.5)"), fractional)

        // 整数相当は小数点を付けない(FTSeconds.format)
        let integral = render([
            FlowStep(action: "tap", locator: FlowLocator(id: "btn"), duration: 2),
        ])
        XCTAssertTrue(integral.contains("tap(\"#btn\", holdSeconds: 2)"), integral)

        // nil = 既定なので引数ごと出さない
        let omitted = render([FlowStep(action: "tap", locator: FlowLocator(id: "btn"))])
        XCTAssertTrue(omitted.contains("tap(\"#btn\")"), omitted)
        XCTAssertFalse(omitted.contains("holdSeconds:"), omitted)
    }

    func testExistEmitsFractionalTimeoutAndOmitsTheDefault() {
        let fractional = render([
            FlowStep(assert: "exists", locator: FlowLocator(id: "msg"), timeout: 1.2),
        ])
        XCTAssertTrue(fractional.contains("exist(\"#msg\", timeout: 1.2)"), fractional)

        // 既定(5秒)と同じなら出さない
        let omitted = render([
            FlowStep(assert: "exists", locator: FlowLocator(id: "msg"), timeout: 5),
        ])
        XCTAssertTrue(omitted.contains("exist(\"#msg\")"), omitted)
        XCTAssertFalse(omitted.contains("timeout:"), omitted)
    }
}
