// 生成するクラス名が Swift の識別子として通るかの判定(`ScenarioCodeGen.isWritableClassName`)。
//
// **ツールが組み立てた出力**なので「誤りは早い段(コンパイラ)で返す」の対象ではない ——
// codegen の口はここ1つで、通すと**コンパイルできない .swift をツールが書き出す**。
// 実地 2026-09-22: `ft_draft_scenario {"className":"9 bad name"}` が
// `class 9 bad name {` をそのまま生成した。**日本語のクラス名は正当**(この repo のシナリオがそれ)。

import FTCore
import XCTest

final class ScenarioCodeGenClassNameTests: XCTestCase {

    func testJapaneseAndPlainNamesAreWritable() {
        XCTAssertTrue(ScenarioCodeGen.isWritableClassName("起動と画面遷移が正しく行われること"))
        XCTAssertTrue(ScenarioCodeGen.isWritableClassName("DraftedScenario"))
        XCTAssertTrue(ScenarioCodeGen.isWritableClassName("_private2"))
    }

    /// 弾くのは3つ: 空 / 数字始まり / 英数字と `_` 以外を含む
    func testDigitLeadingAndSpacedNamesAreRefused() {
        XCTAssertFalse(ScenarioCodeGen.isWritableClassName(""))
        XCTAssertFalse(ScenarioCodeGen.isWritableClassName("9bad"))
        XCTAssertFalse(ScenarioCodeGen.isWritableClassName("9 bad name"))
        XCTAssertFalse(ScenarioCodeGen.isWritableClassName("bad name"))
        XCTAssertFalse(ScenarioCodeGen.isWritableClassName("bad-name"))
        XCTAssertFalse(ScenarioCodeGen.isWritableClassName("../evil"))
    }
}
