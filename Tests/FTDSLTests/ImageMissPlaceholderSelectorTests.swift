// 画像で掴めなかった要素の「飾りの名前」(`<image "…": not found>`)は、利用者が書いた
// セレクタ式ではないので**実行前の構文検証に掛けない**。
//
// 掛けていた頃の実害(実地 2026-09-23 の負荷テスト): `findImage("[Switch]").idIs("sw_notify")` が
// `invalid selector syntax: a clause starting with '<' …` で落ち、**書いた本人のセレクタを誤って
// 名指し**した。dry-run は画像を探せないので必ずこの形になり、findImage / existImage を使う
// シナリオを1本でも含むプロジェクトは **dry-run が丸ごと赤**(= シナリオ作成の中間ゲートが死ぬ)。

import XCTest
@testable import FTCore
@testable import FTDSL

final class ImageMissPlaceholderSelectorTests: XCTestCase {

    func testNotFoundPlaceholderIsNotValidatedAsSelectorSyntax() {
        let element = FTElement(imageMatch: nil, imageLabel: "[Switch]")
        XCTAssertNil(element.selector.preflightError,
                     "画像未発見の飾りの名前が構文エラーとして落ちている: \(element.selector.text)")
        XCTAssertTrue(element.selector.text.contains("[Switch]"),
                      "レポートでどの画像だったか分かる文字列を残すこと")
        XCTAssertTrue(element.selector.text.contains("not found"))
    }

    /// 書けるセレクタが無かった場合(見つかってはいる)も同じ扱い
    func testNoWritableSelectorPlaceholderIsAlsoExempt() {
        let selector = FTElement.placeholderSelector(imageLabel: "[Checkbox]",
                                                     reason: "no writable selector")
        XCTAssertNil(selector.preflightError)
        XCTAssertTrue(selector.structured, "構文検証を通さない印(structured)が付いていること")
    }

    /// 逆向き: 利用者が書いた同じ形の文字列は従来どおり構文エラーで落ちる
    func testUserWrittenAngleBracketSelectorStillFails() {
        XCTAssertNotNil(FTSelector.label("<image \"x\": not found>").preflightError)
    }
}
