// 21_チェック状態の判定元.swift
// fleetest 機能: `checkIsON(prefer:)` / `checkIsOFF(prefer:)`。状態を読む先の優先を1コマンドだけ指定する
// (省略時は実行プロファイルの `preferCheckStateClassifier`)。`.classifier` = 見本
// (vision/classifiers/CheckStateClassifier/[ON]・[OFF])があれば画像の分類器で判定 /
// `.accessibility` = a11y が状態を報告する要素は a11y で、報告しない要素だけ分類器。
// 同じ要素を両方の優先で読むので、片方の経路だけが壊れても赤になる。
// **この SUT に置く意味**: a11y 側は RN の語(`checkbox, checked` / `radio button, unchecked`)を value から読む経路。
// 分類器側は 44x44 の自作部品の枠で切った見本。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class チェック状態を分類器とa11yの両方で判定できること {

    @Test("checkIsON / checkIsOFF は prefer: .classifier でも .accessibility でも判定できる")
    func S0010() {
        scenario {
            scene(1, "初期状態をどちらの優先でも読む") {
                condition {
                    launchApp()
                    tap("#tab_controls")
                }.expectation {
                    for prefer in [CheckStateSource.classifier, .accessibility] {
                        select("#sw_notify").checkIsOFF(prefer: prefer)
                        select("#cb_agree").checkIsOFF(prefer: prefer)
                        select("#radio_a").checkIsON(prefer: prefer)
                        select("#radio_b").checkIsOFF(prefer: prefer)
                    }
                }
            }
            scene(2, "タップした直後の状態をどちらの優先でも読む") {
                action {
                    tap("#sw_notify")
                    tap("#cb_agree")
                    tap("#radio_b")
                }.expectation {
                    // 分類器はスクリーンショットを見るので、タップ直後に絵が追いついていないと古い状態を判定する
                    for prefer in [CheckStateSource.classifier, .accessibility] {
                        select("#sw_notify").checkIsON(prefer: prefer)
                        select("#cb_agree").checkIsON(prefer: prefer)
                        select("#radio_b").checkIsON(prefer: prefer)
                        select("#radio_a").checkIsOFF(prefer: prefer)
                    }
                }
            }
        }
    }
}
