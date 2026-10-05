// 53_読み込みの状態.swift
// 確かめる癖: 読み込み中も本物と同じ #id・ラベルの行が木に居る(出現待ちが早合点で通る)・押せない骨組みの行・
// 末尾の一時的な行(読み込み中・エラー)・1回目は必ず失敗する末尾の読み込み。

import FTDSL

@TestClass
class 読み込みの状態の変化を待てること {

    @Test("読み込み直した直後の行を押す(骨組みが押せるようになるまで待つ)")
    func S0010() {
        scenario {
            scene(1, "開いて読み込みの完了を待つ") {
                condition {
                    launchApp()
                    tap("#nav_loading", scroll: .down)
                }.expectation {
                    select("#txt_loading_state").textIs("state=loaded", waitSeconds: 10)
                    select("#txt_loading_count").textIs("loaded=30")
                }
            }
            scene(2, "読み込み直した直後に #row_l_03 を押す") {
                action {
                    tap("#btn_reload")
                }.expectation {
                    select("#row_l_03").enabledIsFalse()
                }.action {
                    tap("#row_l_03")
                }.expectation {
                    select("#txt_loading_result").textIs("loading=row_l_03")
                    select("#txt_loading_state").textIs("state=loaded")
                }
            }
        }
    }

    @Test("末尾まで送ると必ず1回失敗し、再試行で続きが読み込まれ、最後は終端")
    func S0020() {
        scenario {
            scene(1, "開いて読み込みの完了を待つ") {
                condition {
                    launchApp()
                    tap("#nav_loading", scroll: .down)
                }.expectation {
                    select("#txt_loading_state").textIs("state=loaded", waitSeconds: 10)
                }
            }
            scene(2, "末尾まで送ると読み込みに失敗する") {
                action {
                    scrollToBottom(scrollFrame: "#list_loading")
                }.expectation {
                    exist("#txt_footer_error", waitSeconds: 10)
                    exist("#btn_retry")
                    select("#txt_loading_state").textIs("state=error")
                    select("#txt_loading_count").textIs("loaded=30")
                }
            }
            scene(3, "再試行で 20 行が足される") {
                action {
                    tap("#btn_retry")
                }.expectation {
                    select("#txt_loading_count").textIs("loaded=50", waitSeconds: 10)
                    select("#txt_loading_state").textIs("state=loaded")
                }
            }
            scene(4, "足された行を押す") {
                action {
                    tap("#row_l_35", scroll: .down, maxSwipes: 20)
                }.expectation {
                    select("#txt_loading_result").textIs("loading=row_l_35")
                }
            }
            scene(5, "さらに末尾まで送ると終端") {
                action {
                    scrollToBottom(scrollFrame: "#list_loading")
                }.expectation {
                    exist("#txt_footer_end", waitSeconds: 10)
                    select("#txt_loading_state").textIs("state=end")
                }
            }
        }
    }
}
