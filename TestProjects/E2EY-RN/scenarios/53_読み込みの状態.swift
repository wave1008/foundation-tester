// 53_読み込みの状態.swift
// 確かめる癖: 読み込み中も本物と同じ #id・ラベルの骨組みの行が木に居る(出現待ちが早合点で通る・
// 骨組みは押せない)。末尾の一時的な行(読み込み中・エラー)・1回目は必ず失敗する続きの読み込み。

import FTDSL

@TestClass
class 読み込み中の骨組みと末尾の読み込みを扱えること {

    @Test("読み込み中の行は押せず、state=loaded を待ってから押す")
    func S0010() {
        scenario {
            scene(1, "開く(読み込み中)") {
                condition {
                    launchApp()
                    tap("#nav_loading", scroll: .down)
                }.expectation {
                    // 骨組みの行も同じ #id で居る(存在待ちでは読み込み完了を判定できない)。
                    // state=loading は 2 秒の窓なので、遷移の所要が長いデバイスでは読めない(読まない)
                    exist("#row_l_03")
                }
            }
            scene(2, "読み込み完了を state で待って押す") {
                action {
                    select("#txt_loading_state").textIs("state=loaded", waitSeconds: 6)
                    tap("#row_l_03")
                }.expectation {
                    select("#txt_loading_result").textIs("loading=row_l_03")
                    select("#txt_loading_count").textIs("loaded=30")
                }
            }
        }
    }

    @Test("読み込み直した直後の骨組みの行は無効で、押すと読み込み後の本物の行が押される")
    func S0020() {
        scenario {
            scene(1, "読み込み済みにして押す") {
                condition {
                    launchApp()
                    tap("#nav_loading", scroll: .down)
                    select("#txt_loading_state").textIs("state=loaded", waitSeconds: 6)
                    tap("#row_l_03")
                }.expectation {
                    select("#txt_loading_result").textIs("loading=row_l_03")
                }
            }
            scene(2, "読み込み直した直後は骨組みが無効") {
                action {
                    tap("#btn_reload")
                }.expectation {
                    select("#row_l_05").enabledIsFalse()
                }
            }
            scene(3, "押すと押せるまで待って本物の行が押される") {
                action {
                    tap("#row_l_05")
                }.expectation {
                    select("#txt_loading_result").textIs("loading=row_l_05")
                }
            }
        }
    }

    @Test("末尾で1回目は失敗し、再試行で続きが読まれ、最後は終端")
    func S0030() {
        scenario {
            scene(1, "読み込み済みにする") {
                condition {
                    launchApp()
                    tap("#nav_loading", scroll: .down)
                    select("#txt_loading_state").textIs("state=loaded", waitSeconds: 6)
                }.expectation {
                    select("#txt_loading_count").textIs("loaded=30")
                }
            }
            scene(2, "末尾まで送ると1回目は失敗する") {
                action {
                    scrollToBottom()
                }.expectation {
                    waitForDisplay("#txt_footer_error", waitSeconds: 6)
                    select("#txt_loading_state").textIs("state=error")
                    exist("#btn_retry")
                }
            }
            scene(3, "再試行で 50 件になる") {
                action {
                    tap("#btn_retry")
                }.expectation {
                    select("#txt_loading_count").textIs("loaded=50", waitSeconds: 4)
                    select("#txt_loading_state").textIs("state=loaded")
                }
            }
            scene(4, "さらに末尾まで送ると終端") {
                action {
                    scrollToBottom()
                }.expectation {
                    waitForDisplay("#txt_footer_end", waitSeconds: 4)
                    select("#txt_loading_state").textIs("state=end")
                    exist("#row_l_49")
                }
            }
        }
    }
}
