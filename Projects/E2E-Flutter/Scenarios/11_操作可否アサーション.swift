// 11_操作可否アサーション.swift
// ftester 機能: `isDisabled` / `isEnabled`(要素の enabled 属性の検証)。
// **この SUT に置く意味**: enabled の表現はフレームワークごとに実装が違う
// (Flutter は onPressed: null)ため、a11y ツリーに出る enabled 属性が
// AppDriver から上で同じに見えることをフレームワーク別に確かめる。
// 対象は ui-contract.md のコントロールタブの 2 ボタン(どちらもタップ対象にしない)。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
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
                    isDisabled("#btn_always_disabled")
                    isDisabled("#btn_toggle_target")
                }
            }
            scene(2, "同意すると条件付きボタンだけが有効になる") {
                action {
                    tap("#cb_agree")
                }.expectation {
                    textIs("#txt_cb_agree", "agree=true")
                    isEnabled("#btn_toggle_target")
                    // 常時無効ボタンは影響を受けない
                    isDisabled("#btn_always_disabled")
                }
            }
            scene(3, "同意を外すと条件付きボタンは無効に戻る") {
                action {
                    tap("#cb_agree")
                }.expectation {
                    textIs("#txt_cb_agree", "agree=false")
                    isDisabled("#btn_toggle_target")
                }
            }
        }
    }
}
