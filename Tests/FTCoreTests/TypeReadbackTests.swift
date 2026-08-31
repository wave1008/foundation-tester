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

    // MARK: - 入力欄でないものへ打とうとしている警告

    /// 実測(iOS ヘルスケアの初期設定): 行 `clickable` がラベルと欄を包み、**id は包み側だけ**。
    /// 素直に包みへ `type` すると ok が返るのに欄の値は要求と無関係になる(TypeReadback の doc)
    func testNonInputTargetNamesTheFieldInside() {
        let wrapper = ElementInfo(ref: 1, type: "clickable", identifier: "HeightEntry", label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 22, y: 650, width: 358, height: 60), depth: 2)
        let label = ElementInfo(ref: 2, type: "staticText", identifier: nil, label: "身長",
                                value: nil, placeholder: nil, enabled: true,
                                frame: FTRect(x: 38, y: 670, width: 32, height: 20), depth: 3)
        let field = ElementInfo(ref: 3, type: "textField", identifier: nil, label: nil,
                                value: nil, placeholder: "オプション", enabled: true,
                                frame: FTRect(x: 168, y: 669, width: 196, height: 21), depth: 3)
        let note = TapTargetGeometry.nonInputTypeTargetNote(wrapper, in: [wrapper, label, field])
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("not a text field") == true, note ?? "-")
        // **書ける形で名指しすること**: 内側の欄は無ラベル無 id なので、素の型名だけでは
        // 同型が5つ並ぶ実画面で選べない(2026-08-14 の実画面で判明)
        XCTAssertTrue(note?.contains("#HeightEntry >> .textField") == true, note ?? "-")
    }

    /// **入力欄そのものには出さない**(通常の書き方を壊さない)。
    /// **中に入力欄を持つ入力欄**で試すのが要点 —— iOS の `searchField` は内側に `textField` を
    /// 持つ実在の形で、ここを素通しすると「本物の欄に打っているのに責める」誤検知になる
    /// (中身を持たない欄で試すと、条件を外す変異が 0 件で nil に落ちて素通りする。
    /// 2026-08-14 に変異が生き残って判明)
    func testNonInputTargetIsSilentForARealField() {
        let search = ElementInfo(ref: 1, type: "searchField", identifier: "search", label: nil,
                                 value: nil, placeholder: nil, enabled: true,
                                 frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 2)
        let inner = ElementInfo(ref: 2, type: "textField", identifier: nil, label: nil, value: nil,
                                placeholder: nil, enabled: true,
                                frame: FTRect(x: 4, y: 4, width: 192, height: 32), depth: 3)
        XCTAssertNil(TapTargetGeometry.nonInputTypeTargetNote(search, in: [search, inner]))
    }

    /// **内側の欄がちょうど1つのときだけ言う**: 0個なら Compose のように型が clickable で
    /// 報告される本物の欄を誤って責める / 2個以上ならどれを指すべきか言えない
    func testNonInputTargetStaysSilentWhenItCannotNameOneField() {
        let wrapper = ElementInfo(ref: 1, type: "clickable", identifier: "row", label: nil,
                                  value: nil, placeholder: nil, enabled: true,
                                  frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 2)
        XCTAssertNil(TapTargetGeometry.nonInputTypeTargetNote(wrapper, in: [wrapper]))

        let a = ElementInfo(ref: 2, type: "textField", identifier: nil, label: nil, value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 50, height: 20), depth: 3)
        let b = ElementInfo(ref: 3, type: "textField", identifier: nil, label: nil, value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 50, y: 0, width: 50, height: 20), depth: 3)
        XCTAssertNil(TapTargetGeometry.nonInputTypeTargetNote(wrapper, in: [wrapper, a, b]))
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

    // MARK: - 空白だけの入力(2026-08-18 実測: a11y は空白のみの値を返さない)

    /// 空欄に見えるからと追送すると、**毎周同じ空白が積まれて欄が壊れる**(実測: 4周で12個)。
    /// 打鍵が落ちた場合と区別できないので検証を諦める
    func testWhitespaceOnlyExpectedIsUnverifiableWhenNothingIsRead() {
        XCTAssertEqual(TypeReadback.plan(expected: "   ", actual: ""), .unverifiable)
        XCTAssertEqual(TypeReadback.plan(expected: "\t", actual: ""), .unverifiable)
    }

    /// 空白**だけ**のときの話。見える文字が混じっていれば従来どおり追送する
    /// (打鍵落ちの検出はこちらが本体)
    func testTextWithVisibleCharactersStillResends() {
        XCTAssertEqual(TypeReadback.plan(expected: " a ", actual: ""), .resend(" a "))
        XCTAssertEqual(TypeReadback.plan(expected: "abc", actual: ""), .resend("abc"))
    }

    /// 末尾に空白を足しただけの差分もトリムすれば一致する = 読めない空白でしかありえないので、
    /// 追送しない(2026-08-31 実測で「全体が空白」限定の判定を一般化した)
    func testAppendingSpacesToExistingTextIsUnverifiable() {
        XCTAssertEqual(TypeReadback.plan(expected: "abc  ", actual: "abc"), .unverifiable)
    }

    /// 空白が実際に読めたなら普通に一致する(この規則は読めないときだけ効く)
    func testWhitespaceThatIsActuallyReadBackIsDone() {
        XCTAssertEqual(TypeReadback.plan(expected: "   ", actual: "   "), .done)
    }

    // MARK: - 空白の有無だけの差分は読めない(2026-08-31 実測。上の規則の一般化)

    /// トリムして一致するなら追送・削除のどちらも打たない。先頭・末尾どちらの空白でも同じ
    func testTrimmedEqualDiffsAreUnverifiable() {
        XCTAssertEqual(TypeReadback.plan(expected: "   ", actual: ""), .unverifiable)
        XCTAssertEqual(TypeReadback.plan(expected: "abc ", actual: "abc"), .unverifiable)
    }

    /// トリムしても一致しない差分は従来どおり追送・削除で埋める(空白の一般化が
    /// 可視文字の取りこぼし判定を弱めていないことの対照)
    func testNonWhitespaceDiffsStillResendAsBefore() {
        XCTAssertEqual(TypeReadback.plan(expected: "abc", actual: "ab"), .resend("c"))
        XCTAssertEqual(TypeReadback.plan(expected: "abc", actual: ""), .resend("abc"))
    }
}
