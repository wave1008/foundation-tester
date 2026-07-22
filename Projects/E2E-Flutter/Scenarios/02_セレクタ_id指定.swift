// 02_セレクタ_id指定.swift
// ftester 機能: `#id` セレクタでのタップと、結果 echo Text の完全一致検証(textIs)。
// Flutter は `Semantics(identifier:)` が iOS = accessibilityIdentifier /
// Android = resource-id にマップされるため、#id が両 OS 共通で引ける。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class セレクタのid指定でタップできること {

    @Test("#id セレクタでタップし結果が echo される")
    func S0010() {
        scenario {
            scene(1, "セレクタ画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // 既定(true)だと occlusion-guard が FM 視覚照合を呼び、Flutter の小さな
                    // テキスト領域を「覆われている」と誤判定して落ちることがある
                    // (実際には完全に見えている。2026-07-23 実測)。可視性の検証は 01 が行う。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    textIs("#txt_selector_result", "result=-")
                }
            }
            scene(2, "#btn_allow を id 指定でタップ") {
                action {
                    tap("#btn_allow")
                }.expectation {
                    textIs("#txt_selector_result", "result=allow")
                }
            }
            scene(3, "#btn_shared_label を id 指定でタップ") {
                action {
                    tap("#btn_shared_label")
                }.expectation {
                    textIs("#txt_selector_result", "result=shared")
                }
            }
            scene(4, "#btn_selector_reset で結果をクリア") {
                action {
                    tap("#btn_selector_reset")
                }.expectation {
                    textIs("#txt_selector_result", "result=-")
                }
            }
        }
    }
}
