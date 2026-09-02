import XCTest
import FTCore
@testable import FTFoundationModels

/// `FMReplayDelegate.healPrompt` は、heal プロンプト本文を組み立てるだけの純粋関数
/// (LanguageModelSession を呼ばない)。2026-09-02 の実機実測: FM が壊れたロケータを
/// そのままオウム返ししていた(triage は同じ木から正解を出せていたので、木ではなくプロンプトの
/// 問題)。ここでは①壊れたロケータの文字列が名指しされること②それを答えにするなという指示が
/// あること③要素一覧が含まれること④note の有無で内容が変わることを固定する。
/// 期待値は production の文言を再利用せず、テスト側にリテラルで書く(文言を消す変異を素通ししないため)。
final class HealPromptTests: XCTestCase {

    private func tapStep(id: String, note: String? = nil) -> FlowStep {
        FlowStep(action: "tap", locator: FlowLocator(id: id), note: note)
    }

    /// 壊れたロケータの生テキスト(`id=...`)がプロンプトへ名指しで載ること
    func testPromptNamesTheBrokenLocatorVerbatim() {
        let step = tapStep(id: "btn_heal_v1")
        let prompt = FMReplayDelegate.healPrompt(step: step, renderedElements: "(elements)")

        XCTAssertTrue(prompt.contains("id=btn_heal_v1"),
                       "壊れたロケータの文字列がそのままプロンプトに載ること: \(prompt)")
    }

    /// 「それを答えにするな」に相当する指示が、壊れたロケータの近くにあること
    func testPromptTellsTheModelNotToAnswerWithTheBrokenLocator() {
        let step = tapStep(id: "btn_heal_v1")
        let prompt = FMReplayDelegate.healPrompt(step: step, renderedElements: "(elements)")

        XCTAssertTrue(prompt.contains("no longer exists on this screen"))
        XCTAssertTrue(prompt.contains("do not answer with it"))
    }

    /// 要素一覧(rendered)がそのままプロンプトに含まれること
    func testPromptIncludesTheRenderedElementList() {
        let step = tapStep(id: "btn_heal_v1")
        let rendered = "button \"修復対象\" id=btn_heal_v2"
        let prompt = FMReplayDelegate.healPrompt(step: step, renderedElements: rendered)

        XCTAssertTrue(prompt.contains(rendered))
    }

    /// step.note があるとき: 意図の一文がプロンプトに載ること
    func testPromptIncludesIntentWhenNotePresent() {
        let step = tapStep(id: "btn_heal_v1", note: "修復対象を押す")
        let prompt = FMReplayDelegate.healPrompt(step: step, renderedElements: "(elements)")

        XCTAssertTrue(prompt.contains("Intent of this step: 修復対象を押す"))
    }

    /// step.note が無いとき: 「Intent of this step」の行自体が出ないこと
    func testPromptOmitsIntentLineWhenNoteAbsent() {
        let step = tapStep(id: "btn_heal_v1", note: nil)
        let prompt = FMReplayDelegate.healPrompt(step: step, renderedElements: "(elements)")

        XCTAssertFalse(prompt.contains("Intent of this step"))
    }
}
