// 03_セレクタ_ラベルと部分一致.swift
// ftester 機能: ラベルの一致規則の検証(docs/design.md §10)。
// **素の文字列は完全一致だけ**で、部分一致は `*語*` / `語*` / `*語` と書いたときにしか起きない。
// `許可` は `通知を許可` の部分文字列だが、素で書く限り #btn_allow(完全一致)しか掴まない。
// これが本ファイルの唯一の検証点である。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class ラベルの一致規則が明示どおりであること {

    @Test("素の文字列は完全一致・部分一致は記法で明示したときだけ")
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
