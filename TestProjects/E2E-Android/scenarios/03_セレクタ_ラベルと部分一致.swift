// 03_セレクタ_ラベルと部分一致.swift
// ftester 機能: ラベルの一致規則の検証(docs/design.md §10)。
// **素の文字列は完全一致だけ**で、部分一致は `*語*` / `語*` / `*語` と書いたときにしか起きない。
// `許可` は `通知を許可` の部分文字列だが、素で書く限り #btn_allow(完全一致)しか掴まない。
// これが本ファイルの唯一の検証点である。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class ラベルの一致規則が明示どおりであること {

    @Test("素の文字列は完全一致・部分一致は記法で明示したときだけ")
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
            scene(2, "「通知を許可」は完全一致するラベルでそのままタップされる") {
                action {
                    tap("通知を許可")
                }.expectation {
                    select("#txt_selector_result").textIs("result=allow_notification")
                }
            }
            scene(3, "結果をクリア") {
                action {
                    tap("#btn_selector_reset")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(4, "「許可」は #btn_allow(完全一致)が選ばれる(「通知を許可」には当たらない)") {
                action {
                    tap("許可")
                }.expectation {
                    select("#txt_selector_result").textIs("result=allow")
                }
            }
            scene(5, "結果をクリア") {
                action {
                    tap("#btn_selector_reset")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(6, "`*知を許*` と書いたときだけ部分一致で「通知を許可」を掴む") {
                action {
                    tap("*知を許*")
                }.expectation {
                    select("#txt_selector_result").textIs("result=allow_notification")
                }
            }
            scene(7, "同じ文字列を素で書くと**どの要素にも当たらない**(部分一致は暗黙には起きない)") {
                expectation {
                    // 直前の scene 6 が「*付きなら当たる」ことを示しているので、
                    // ここが空振りなのは綴り誤りではなく完全一致契約そのものの確認になる
                    notExist("知を許")
                }
            }
        }
    }
}
