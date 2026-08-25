// `fleetest api run`(拡張の並列経路)が「用意する台数」を決めるための本数の読み方。
//
// この経路は**シナリオ一覧をビルドと並行に解決する**ので、台数を決める時点では一覧が無い。
// 確定しているのは `--scenario` の指定文字列だけ ——
//   `Class.method`(明示 ID)… 1つにつき高々1本。合計が本数の上限として使える
//   `Class`(クラス名) / 指定なし … 何本になるか分からない。**絞らない**(全件実行の並列度を殺さない)
// 判断はこの純粋関数1つに閉じる(ApiRunCommand は結果を使うだけ)。

import XCTest
@testable import fleetest

final class ApiRunExactScenarioCountTests: XCTestCase {

    func testAllExactIDsGiveTheirCount() {
        XCTAssertEqual(ApiRun.exactScenarioCount(["A.S0010"]), 1)
        XCTAssertEqual(ApiRun.exactScenarioCount(["A.S0010", "B.S0020", "C.S0030"]), 3)
    }

    /// クラス名が1つでも混ざれば「分からない」= 絞らない(0)
    func testClassNameSelectorDisablesTheCap() {
        XCTAssertEqual(ApiRun.exactScenarioCount(["A"]), 0)
        XCTAssertEqual(ApiRun.exactScenarioCount(["A.S0010", "B"]), 0)
    }

    /// 指定なし(全件)も絞らない
    func testEmptySelectionDisablesTheCap() {
        XCTAssertEqual(ApiRun.exactScenarioCount([]), 0)
    }

    /// 日本語のクラス名・メソッド名でも同じ(この repo のシナリオは日本語名)
    func testJapaneseIdentifiersAreHandled() {
        XCTAssertEqual(ApiRun.exactScenarioCount(["横向きでも操作できること.S0010"]), 1)
        XCTAssertEqual(ApiRun.exactScenarioCount(["横向きでも操作できること"]), 0)
    }
}
