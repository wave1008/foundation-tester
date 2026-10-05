// 53_読み込みの状態.swift
// 確かめる癖: Paging の LoadState 相当。読み込み中の骨組みの行が本物と同じ #id・ラベルで居る(出現待ちが
// 早合点で通る・押せない)・末尾の一時的な行(読み込み中 → エラー)・再試行・これ以上ありません。

import FTDSL

@TestClass
class 読み込みの状態を見分けられること {

    @Test("読み込み中の骨組みは同じ #id で居て、押せるようになってから押すと echo が出る")
    func S0010() {
        scenario {
            scene(1, "開いた直後は読み込み中") {
                condition {
                    launchApp()
                    tap("#nav_loading", scroll: .down)
                }.expectation {
                    select("#txt_loading_state").textIs("state=loading")
                    // 骨組みも本物と同じ #id・ラベルなので exist は通ってしまう(早合点)
                    exist("#row_l_03")
                }
            }
            scene(2, "押せるようになってから押す") {
                action {
                    select("#txt_loading_state").textIs("state=loaded")
                    tap("#row_l_03")
                }.expectation {
                    select("#txt_loading_result").textIs("loading=row_l_03")
                    select("#txt_loading_count").textIs("loaded=30")
                }
            }
        }
    }

    @Test("読み込み直した直後の行は押せない")
    func S0020() {
        scenario {
            scene(1, "読み込み済みにする") {
                condition {
                    launchApp()
                    tap("#nav_loading", scroll: .down)
                    select("#txt_loading_state").textIs("state=loaded")
                }.expectation {
                    exist("#row_l_03")
                }
            }
            scene(2, "読み込み直すとまた骨組み") {
                action {
                    tap("#btn_reload")
                }.expectation {
                    select("#txt_loading_state").textIs("state=loading")
                    select("#row_l_03").enabledIsFalse()
                    select("#txt_loading_result").textIs("loading=none")
                }
            }
            scene(3, "終わってから押すと echo が出る") {
                action {
                    select("#txt_loading_state").textIs("state=loaded")
                    tap("#row_l_03")
                }.expectation {
                    select("#txt_loading_result").textIs("loading=row_l_03")
                }
            }
        }
    }

    @Test("末尾でエラー → 再試行 → 続きの行 → これ以上ありません")
    func S0030() {
        scenario {
            scene(1, "読み込み済みにして末尾まで送る") {
                condition {
                    launchApp()
                    tap("#nav_loading", scroll: .down)
                    select("#txt_loading_state").textIs("state=loaded")
                }.action {
                    scrollToBottom()
                }.expectation {
                    // 1回目の追加読み込みは必ず失敗する
                    exist("#txt_footer_error")
                    select("#txt_loading_state").textIs("state=error")
                    select("#txt_loading_count").textIs("loaded=30")
                }
            }
            scene(2, "再試行") {
                action {
                    tap("#btn_retry", scroll: .down)
                }.expectation {
                    select("#txt_loading_state").textIs("state=loaded")
                    select("#txt_loading_count").textIs("loaded=50")
                }
            }
            scene(3, "追加された行を押す") {
                action {
                    tap("#row_l_49", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_loading_result").textIs("loading=row_l_49")
                }
            }
            scene(4, "さらに末尾まで送るとこれ以上ありません") {
                action {
                    scrollToBottom()
                }.expectation {
                    exist("#txt_footer_end")
                    select("#txt_loading_state").textIs("state=end")
                }
            }
        }
    }
}
