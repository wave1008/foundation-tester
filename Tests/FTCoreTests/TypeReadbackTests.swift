// XCUITest ランナー /type の読み返し判定(TypeReadback)。
// 実行系(BridgeRouter.handleType)はデバイスでしか動かないため、判定の境界だけここで固定する。
// 特に「二重入力に倒れる誤判定」(nil と空文字の混同・曖昧一致)は e2e では滅多に出ないので、
// ここで守る。

import XCTest
import FTCore

final class TypeReadbackTests: XCTestCase {

    // MARK: - plan(取りこぼし / 二重入力 / 加工の3分岐)

    func testPlanDoneWhenActualMatches() {
        XCTAssertEqual(TypeReadback.plan(expected: "persist99", actual: "persist99"), .done)
        XCTAssertEqual(TypeReadback.plan(expected: "", actual: ""), .done)
    }

    func testPlanResendsOnlyTheMissingSuffix() {
        // 実測の取りこぼしの形: 毎周 6 割前後しか入らない(docs/verification.md)
        XCTAssertEqual(TypeReadback.plan(expected: "hello123", actual: "hel"),
                       .resend("lo123"))
        // 1文字も入らなかった周(空文字は「未入力」であって「読めない」ではない)
        XCTAssertEqual(TypeReadback.plan(expected: "hello123", actual: ""),
                       .resend("hello123"))
    }

    func testPlanDeletesOnlyTheExcessOnDoubleInput() {
        XCTAssertEqual(TypeReadback.plan(expected: "abc", actual: "abcabc"), .deleteExcess(3))
    }

    func testPlanGivesUpWhenInputWasTransformed() {
        // 自動修正・書式付け・マスク欄(•••)は前方一致にならない → 追送すると値を壊す
        XCTAssertEqual(TypeReadback.plan(expected: "secret42", actual: "••••••••"), .unverifiable)
        XCTAssertEqual(TypeReadback.plan(expected: "5551234", actual: "555-1234"), .unverifiable)
    }

    // MARK: - value(読み返しの対象解決)

    private func element(ref: Int, type: String = "textField", id: String? = nil,
                         value: String? = nil, placeholder: String? = nil,
                         frame: FTRect = FTRect(x: 0, y: 0, width: 100, height: 40)) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: value,
                    placeholder: placeholder, enabled: true, frame: frame, depth: 0)
    }

    func testValueMatchesByIdentifier() {
        let target = element(ref: 1, id: "field_single")
        // キーボード出現で frame が動いても identifier で追える
        let moved = element(ref: 7, id: "field_single", value: "abc",
                            frame: FTRect(x: 0, y: 200, width: 100, height: 40))
        XCTAssertEqual(TypeReadback.value(of: target, in: [moved]), "abc")
    }

    func testValueFallsBackToFrameWhenNoIdentifier() {
        let frame = FTRect(x: 10, y: 20, width: 100, height: 40)
        let target = element(ref: 1, frame: frame)
        let found = element(ref: 3, value: "xyz", frame: frame)
        let other = element(ref: 4, value: "no", frame: FTRect(x: 0, y: 0, width: 50, height: 40))
        XCTAssertEqual(TypeReadback.value(of: target, in: [other, found]), "xyz")
    }

    func testValueIsNilWhenTargetMissing() {
        let target = element(ref: 1, id: "field_single")
        XCTAssertNil(TypeReadback.value(of: target, in: [element(ref: 2, id: "field_other")]))
    }

    /// **候補が複数なら nil**(空の同名欄を「入っていない」と誤読して追送すると、
    /// 本当のフォーカス欄へ二重入力する)。first で拾ってはいけない
    func testValueIsNilWhenIdentifierIsAmbiguous() {
        let target = element(ref: 1, id: "dup")
        let empty = element(ref: 2, id: "dup", value: nil)
        let typed = element(ref: 3, id: "dup", value: "abc")
        XCTAssertNil(TypeReadback.value(of: target, in: [empty, typed]))
    }

    // MARK: - normalizedValue(placeholder と nil の畳み込み)

    func testNormalizedValueTreatsPlaceholderAsEmpty() {
        // iOS は空欄の value に placeholder を返す(SwiftUI TextField 実測)
        XCTAssertEqual(TypeReadback.normalizedValue(of:
            element(ref: 1, value: "単一行", placeholder: "単一行")), "")
        XCTAssertEqual(TypeReadback.normalizedValue(of: element(ref: 1, value: nil)), "")
        XCTAssertEqual(TypeReadback.normalizedValue(of:
            element(ref: 1, value: "abc", placeholder: "単一行")), "abc")
    }

    // MARK: - isTextInput(検証対象の型)

    func testIsTextInputCoversInputTypesOnly() {
        // CMP は textView・SwiftUI/Flutter は textField / secureTextField を出す(実測)
        for type in ["textField", "secureTextField", "textView", "searchField"] {
            XCTAssertTrue(TypeReadback.isTextInput(element(ref: 1, type: type)), type)
        }
        // 値を読めない型を検証対象にすると必ず 422 で落ちる経路になる
        XCTAssertFalse(TypeReadback.isTextInput(element(ref: 1, type: "button")))
        XCTAssertFalse(TypeReadback.isTextInput(element(ref: 1, type: "staticText")))
    }
}
