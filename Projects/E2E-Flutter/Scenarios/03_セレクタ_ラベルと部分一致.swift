// 03_セレクタ_ラベルと部分一致.swift
// ftester 機能: ラベルセレクタの「完全一致優先 → 無ければ部分一致(contains)」契約の検証
// (docs/design.md §10)。`許可` は `通知を許可` にも部分一致するが、画面上に `許可` 完全一致の
// 要素(#btn_allow)が存在する限りそちらが選ばれることを確認する。
// これが本ファイルの唯一の検証点である。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class ラベルセレクタが完全一致を優先すること {

    @Test("完全一致するラベルがあれば部分一致より優先される")
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
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
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
