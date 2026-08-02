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

    /// select は action(操作)として生成される。exist(assert)とコード生成の分岐が違うことを固定する
    func testSelectEmitsTheTimeoutAndOmitsTheDefault() {
        let explicit = render([
            FlowStep(action: "select", locator: FlowLocator(id: "msg"), timeout: 1.2),
        ])
        XCTAssertTrue(explicit.contains("select(\"#msg\", timeout: 1.2)"), explicit)

        let omitted = render([
            FlowStep(action: "select", locator: FlowLocator(id: "msg"), timeout: 5),
        ])
        XCTAssertTrue(omitted.contains("select(\"#msg\")"), omitted)
        XCTAssertFalse(omitted.contains("timeout:"), omitted)
    }

    /// **廃止済みの `optional:` を生成コードに復活させない**。録画 JSON に古い `optional` キーが
    /// 残っていても FlowStep が読み捨てるので、生成結果はコンパイルできる形のままになる
    /// **スクロール領域の指定は往復で消えてはいけない**。落とすと生成コードが黙って
    /// 全画面スワイプに戻り、実行と生成物の意味が食い違う
    func testScrollToEmitsScrollFrameAndMargins() {
        let code = render([
            FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"),
                     direction: "up", maxSwipes: 15,
                     scrollFrame: FlowLocator(id: "list_rows"),
                     startMarginRatio: 0.3, endMarginRatio: 0.1),
        ])
        XCTAssertTrue(code.contains("scrollFrame: \"#list_rows\""), code)
        XCTAssertTrue(code.contains("startMarginRatio: 0.3"), code)
        XCTAssertTrue(code.contains("endMarginRatio: 0.1"), code)

        // 未指定なら引数ごと出さない(既定ケースで生成コードを太らせない)
        let plain = render([
            FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_40"), direction: "up"),
        ])
        XCTAssertFalse(plain.contains("scrollFrame:"), plain)
        XCTAssertFalse(plain.contains("MarginRatio:"), plain)
    }

    /// notExist(scroll:) も同じ規則(scroll 引数を再構成する唯一のもう1箇所)
    func testNotExistWithScrollEmitsScrollFrame() {
        let code = render([
            FlowStep(assert: "notExists", locator: FlowLocator(id: "row_99"),
                     direction: "up", maxSwipes: 3,
                     scrollFrame: FlowLocator(id: "list_rows")),
        ])
        XCTAssertTrue(code.contains("scroll: .down"), code)
        XCTAssertTrue(code.contains("scrollFrame: \"#list_rows\""), code)
    }

    func testGeneratedCodeNeverEmitsTheRemovedOptionalArgument() throws {
        let json = """
        {"action":"tap","locator":{"id":"btn"},"optional":true}
        """
        let step = try JSONDecoder().decode(FlowStep.self, from: Data(json.utf8))
        let code = render([step])
        XCTAssertTrue(code.contains("tap(\"#btn\")"), code)
        XCTAssertFalse(code.contains("optional"), code)
    }
}
