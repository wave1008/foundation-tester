// 掴んだ時点の要素だけで判定できるアサーション(FTDSL のチェーンの初回判定に使う)。
// `exist("#x").textIs("y")` は掴んだ値で先に判定し、満たしていなければ従来どおり
// StepExecutor が取り直しながらポーリングする(満たしていればデバイス往復が 0 回になる)。
//
// **判定規則は StepExecutor と同じ関数を使う**(matchedText / negativeAssertSatisfied)。
// ここで独自に比較すると、同じアサートがチェーン経路と実機経路で違う答えを出す。

import Foundation

public enum HeldElementAssert {

    /// 掴んだ値だけで判定した結果。**nil = このアサートは保持値で判定しない**(必ず実機を見る)。
    /// 判定しないもの:
    /// - `exists` / `notExists` / `count`: 今の画面に在るか(個数)は過去の値から言えない
    /// - `checked` / `notChecked`: 「checked を実際に観測したか」の追跡が実機経路にあり、
    ///   飛ばすと `checkIsOFF` の誤用警告(状態を持たない要素を指している)が出なくなる
    /// - `screenMatches` / `keyboardShown` / `keyboardNotShown`: 要素の値ではなく画面全体を見る
    public static func satisfied(assert: String, expected: String?,
                                 element: ElementInfo) -> Bool? {
        switch assert {
        case "idEquals":
            guard let expected else { return nil }
            return element.identifier == expected
        case "valueEquals", "textEquals", "textContains", "textMatches",
             "textStartsWith", "textEndsWith", "textMatchesDateFormat",
             "valueContains", "valueMatches", "valueStartsWith", "valueEndsWith",
             "valueMatchesDateFormat":
            guard let expected else { return nil }
            return StepExecutor.matchedText(actualText(assert, element),
                                            expected: expected, assert: assert) != nil
        case "textNotEquals", "textIsEmpty", "textIsNotEmpty",
             "textStartsWithNot", "textContainsNot", "textEndsWithNot", "textMatchesNot",
             "valueNotEquals", "valueIsEmpty", "valueIsNotEmpty",
             "valueStartsWithNot", "valueContainsNot", "valueEndsWithNot", "valueMatchesNot":
            return StepExecutor.negativeAssertSatisfied(assert, actual: actualText(assert, element),
                                                        expected: expected)
        case "enabled":
            return element.enabled
        case "disabled":
            return !element.enabled
        default:
            return nil
        }
    }

    /// text 系は label・value 系は value(実機経路の executeAssertTextComparison と同じ振り分け)
    private static func actualText(_ assert: String, _ element: ElementInfo) -> String? {
        assert.hasPrefix("value") ? element.value : element.label
    }
}
