// 02_セレクタ_id指定.swift
// ftester 機能: `#id` セレクタでのタップと、結果 echo Text の完全一致検証(textIs)。
// RN の `testID` が iOS = accessibilityIdentifier / Android = resource-id にマップされるため、
// #id が両 OS 共通で引ける。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class セレクタのid指定でタップできること {

    @Test("#id セレクタでタップし結果が echo される")
    func S0010() {
        scenario {
            scene(1, "セレクタ画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // 起動直後は a11y ツリー完成後もポインタ入力を一時的に取りこぼす実装が
                    // Flutter で実測されている。RN で同じ罠があるかは未検証だが、害の無い
                    // 1往復なので安全側として残す。
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
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(2, "#btn_allow を id 指定でタップ") {
                action {
                    tap("#btn_allow")
                }.expectation {
                    select("#txt_selector_result").textIs("result=allow")
                }
            }
            scene(3, "#btn_shared_label を id 指定でタップ") {
                action {
                    tap("#btn_shared_label")
                }.expectation {
                    select("#txt_selector_result").textIs("result=shared")
                }
            }
            scene(4, "#btn_selector_reset で結果をクリア") {
                action {
                    tap("#btn_selector_reset")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
        }
    }
}
