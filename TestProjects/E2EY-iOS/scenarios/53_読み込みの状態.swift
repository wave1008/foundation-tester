// 53_読み込みの状態.swift
// 確かめる癖: 読み込み中も本物と同じ #id・ラベルの骨組みの行が木に居る(出現待ちが早合点で通る・押しても何も起きない)。
// 末尾の一時的な行(読み込み中・エラー)・1回目は必ず失敗する追加読み込み。

import FTDSL

@TestClass
class 読み込みの状態を見分けられること {

    @Test("骨組みの行は押せず、読み込み直した直後も同じ")
    func S0010() {
        scenario {
            scene(1, "入った直後は骨組みの行(押しても何も起きない)") {
                condition {
                    launchApp()
                    tap("#nav_loading")
                }.action {
                    exist("#row_l_03", requireVisible: false)
                    tap("#row_l_03")
                }.expectation {
                    select("#txt_loading_state").textIs("state=loading")
                    select("#txt_loading_result").textIs("loading=none")
                }
            }
            scene(2, "読み込み完了を待って本物の行を押す") {
                action {
                    select("#txt_loading_state").textIs("state=loaded", waitSeconds: 10)
                    tap("#row_l_03")
                }.expectation {
                    select("#txt_loading_result").textIs("loading=row_l_03")
                    select("#txt_loading_count").textIs("loaded=30")
                }
            }
            scene(3, "読み込み直した直後に押しても echo は変わらない") {
                action {
                    tap("#btn_reload")
                    tap("#row_l_04")
                }.expectation {
                    select("#txt_loading_state").textIs("state=loading")
                    select("#txt_loading_result").textIs("loading=none")
                }
            }
        }
    }

    @Test("末尾でエラー → 再試行で 50 行 → 末尾")
    func S0020() {
        scenario {
            scene(1, "読み込み完了後に末尾へ送る") {
                condition {
                    launchApp()
                    tap("#nav_loading")
                    select("#txt_loading_state").textIs("state=loaded", waitSeconds: 10)
                }.action {
                    scrollToBottom()
                }.expectation {
                    select("#txt_footer_error", waitSeconds: 10).textIs("読み込みに失敗しました")
                    select("#txt_loading_state").textIs("state=error")
                }
            }
            scene(2, "再試行") {
                action {
                    tap("#btn_retry")
                }.expectation {
                    select("#txt_loading_count", waitSeconds: 10).textIs("loaded=50")
                    select("#txt_loading_state").textIs("state=loaded")
                }
            }
            scene(3, "さらに末尾まで送ると終わり") {
                action {
                    scrollToBottom()
                }.expectation {
                    select("#txt_footer_end", waitSeconds: 10).textIs("これ以上ありません")
                    select("#txt_loading_state").textIs("state=end")
                }
            }
        }
    }
}
