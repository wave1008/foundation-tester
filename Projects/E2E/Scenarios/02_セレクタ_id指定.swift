// 02_セレクタ_id指定.swift
// ftester 機能: `#id` セレクタでのタップと、結果 echo Text の完全一致検証(textIs)。
// #btn_item_1/2/3 のような同一ラベル要素の区別は 04 のセレクタ_型と序数 で扱う。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class セレクタのid指定でタップできること {

    @Test("#id セレクタでタップし結果が echo される")
    func S0010() {
        scenario {
            scene(1, "セレクタ画面を開く") {
                condition {
                    launchApp()
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
