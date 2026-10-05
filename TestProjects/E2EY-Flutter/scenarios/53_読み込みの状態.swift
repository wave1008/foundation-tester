// 53_読み込みの状態.swift
// 確かめる癖: 読み込み中の骨組みの行が本物と同じ #id・ラベルで木に居る(押せない)・
// 末尾の一時的な行(読み込み中 → 失敗 → 再試行)で「末尾に着いた」を誤判定しない。

import FTDSL

@TestClass
class 読み込みの状態を見分けられること {

    @Test("骨組みの行を押すと、押せるようになるのを待って本物の行が押される")
    func S0010() {
        scenario {
            scene(1, "開いた直後の骨組みの行を押す") {
                condition {
                    launchApp()
                    tap("#nav_loading", scroll: .down)
                }.action {
                    tap("#row_l_03")
                }.expectation {
                    select("#txt_loading_result").textIs("loading=row_l_03")
                    select("#txt_loading_state").textIs("state=loaded", waitSeconds: 8)
                    select("#txt_loading_count").textIs("loaded=30")
                }
            }
        }
    }

    @Test("読み込み直した直後の行は無効で、読み込み後に押せる")
    func S0020() {
        scenario {
            scene(1, "読み込み済みにする") {
                condition {
                    launchApp()
                    tap("#nav_loading", scroll: .down)
                }.expectation {
                    select("#txt_loading_state").textIs("state=loaded", waitSeconds: 8)
                }
            }
            scene(2, "読み込み直した直後の骨組みの行は無効") {
                action {
                    tap("#btn_reload")
                }.expectation {
                    select("#row_l_05").enabledIsFalse()
                }
            }
            scene(3, "押すと読み込み後の本物の行が押される") {
                action {
                    tap("#row_l_05")
                }.expectation {
                    select("#txt_loading_result").textIs("loading=row_l_05")
                    select("#txt_loading_state").textIs("state=loaded", waitSeconds: 8)
                }
            }
        }
    }

    @Test("末尾で失敗 → 再試行 → 続きの行 → 末尾")
    func S0030() {
        scenario {
            scene(1, "読み込み済みにする") {
                condition {
                    launchApp()
                    tap("#nav_loading", scroll: .down)
                }.expectation {
                    select("#txt_loading_state").textIs("state=loaded", waitSeconds: 8)
                }
            }
            scene(2, "末尾まで送ると 1 回目は失敗する") {
                action {
                    scrollTo("#btn_retry", maxSwipes: 30)
                }.expectation {
                    select("#txt_footer_error").textIs("読み込みに失敗しました")
                    select("#txt_loading_state").textIs("state=error")
                }
            }
            scene(3, "再試行すると続きの行が足される") {
                action {
                    tap("#btn_retry")
                }.expectation {
                    select("#txt_loading_state").textIs("state=loaded", waitSeconds: 8)
                    select("#txt_loading_count").textIs("loaded=50")
                }.action {
                    tap("#row_l_49", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_loading_result").textIs("loading=row_l_49")
                }
            }
            scene(4, "さらに末尾まで送るとこれ以上ない") {
                action {
                    scrollTo("#txt_footer_end", maxSwipes: 30)
                }.expectation {
                    select("#txt_loading_state").textIs("state=end")
                }
            }
        }
    }
}
