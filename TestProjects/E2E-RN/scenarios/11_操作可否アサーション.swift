// 11_操作可否アサーション.swift
// ftester 機能: `enabledIsFalse` / `enabledIsTrue`(要素の enabled 属性の検証)。
// **この SUT に置く意味**: enabled の表現はフレームワークごとに実装が違う
// (RN は `Pressable` の `disabled` + `accessibilityState.disabled`)ため、a11y ツリーに出る
// enabled 属性が AppDriver から上で同じに見えることをフレームワーク別に確かめる。
// 対象は ui-contract.md のコントロールタブの 2 ボタン(どちらもタップ対象にしない)。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class 操作可否アサーションが正しく判定できること {

    @Test("常時無効ボタンと条件付きボタンの enabled 状態を判定する")
    func S0010() {
        scenario {
            scene(1, "初期状態ではどちらのボタンも無効") {
                condition {
                    launchApp()
                    tap("#tab_controls")
                    tap("#btn_controls_reset")
                }.expectation {
                    select("#btn_always_disabled").enabledIsFalse()
                    select("#btn_toggle_target").enabledIsFalse()
                }
            }
            scene(2, "同意すると条件付きボタンだけが有効になる") {
                action {
                    tap("#cb_agree")
                }.expectation {
                    select("#txt_cb_agree").textIs("agree=true")
                    select("#btn_toggle_target").enabledIsTrue()
                    // 常時無効ボタンは影響を受けない
                    select("#btn_always_disabled").enabledIsFalse()
                }
            }
            scene(3, "同意を外すと条件付きボタンは無効に戻る") {
                action {
                    // group は記録に [名前] を前置するだけのまとまり(実行・失敗の扱いは素の列と同じ)
                    group("同意を外す") {
                        select("#cb_agree").enabledIsTrue()
                        tap("#cb_agree")
                    }
                }.expectation {
                    select("#txt_cb_agree").textIs("agree=false")
                    select("#btn_toggle_target").enabledIsFalse()
                }
            }
        }
    }
}
