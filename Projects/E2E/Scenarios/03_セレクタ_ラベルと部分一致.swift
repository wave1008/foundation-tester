// 03_セレクタ_ラベルと部分一致.swift
// ftester 機能: ラベルセレクタの「完全一致優先 → 無ければ部分一致(contains)」契約の検証
// (docs/design.md §10)。`許可` は `通知を許可` にも部分一致するが、画面上に `許可` 完全一致の
// 要素(#btn_allow)が存在する限りそちらが選ばれることを確認する。
// これが本ファイルの唯一の検証点である。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class ラベルセレクタが完全一致を優先すること {

    @Test("完全一致するラベルがあれば部分一致より優先される")
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
            scene(2, "「通知を許可」は完全一致するラベルでそのままタップされる") {
                action {
                    tap("通知を許可")
                }.expectation {
                    textIs("#txt_selector_result", "result=allow_notification")
                }
            }
            scene(3, "結果をクリア") {
                action {
                    tap("#btn_selector_reset")
                }.expectation {
                    textIs("#txt_selector_result", "result=-")
                }
            }
            scene(4, "「許可」は #btn_allow(完全一致)が選ばれる(「通知を許可」への部分一致は採用されない)") {
                action {
                    tap("許可")
                }.expectation {
                    textIs("#txt_selector_result", "result=allow")
                }
            }
        }
    }
}
