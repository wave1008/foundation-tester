// 02_セレクタ_id指定.swift
// ftester 機能: `#id` セレクタでのタップと、結果 echo Text の完全一致検証(textIs)。
// iOS ネイティブでは SwiftUI の .accessibilityIdentifier がそのまま #id になる
// (Android の testTagsAsResourceId のような再適用は不要)。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
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
