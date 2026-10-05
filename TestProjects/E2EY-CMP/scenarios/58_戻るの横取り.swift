// 58_戻るの横取り.swift
// 確かめる癖: 戻る(#btn_back・システムの戻る・iOS のエッジスワイプ)が遷移しないで終わる(開いたパネルを閉じるだけ)・
// 戻るのあとに確認ダイアログが割り込む。docs/commands.md の back() の行(iOS の独自ナビはエッジスワイプに落ちる)。

import FTDSL

@TestClass
class 戻るが横取りされても扱えること {

    @Test("欄が空のままなら戻る(back=clean)")
    func S0010() {
        scenario {
            scene(1, "編集画面を開く") {
                condition {
                    launchApp()
                    tap("#nav_back_guard", scroll: .down)
                    tap("#btn_open_editor")
                }.expectation {
                    select("#txt_screen_title").textIs("編集")
                }
            }
            scene(2, "戻る") {
                action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_screen_title").textIs("戻るの横取り")
                    select("#txt_back_result").textIs("back=clean")
                }
            }
        }
    }

    @Test("パネルが開いていると戻るはパネルを閉じるだけ")
    func S0020() {
        scenario {
            scene(1, "パネルを開く") {
                condition {
                    launchApp()
                    tap("#nav_back_guard", scroll: .down)
                    tap("#btn_open_editor")
                }.action {
                    tap("#btn_open_panel")
                }.expectation {
                    select("#txt_editor_state").textIs("panel=open")
                    exist("#txt_panel")
                }
            }
            scene(2, "システムの戻るでパネルだけが閉じる") {
                action {
                    back()
                }.expectation {
                    select("#txt_editor_state").textIs("panel=closed")
                    select("#txt_screen_title").textIs("編集")
                }
            }
            scene(3, "もう一度戻ると画面が戻る") {
                action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("戻るの横取り")
                    select("#txt_back_result").textIs("back=clean")
                }
            }
        }
    }

    @Test("欄に文字があると確認ダイアログ: 続ける → 破棄")
    func S0030() {
        scenario {
            scene(1, "文字を打って戻る") {
                condition {
                    launchApp()
                    tap("#nav_back_guard", scroll: .down)
                    tap("#btn_open_editor")
                }.action {
                    type("#field_title", "abc")
                    tap("#btn_back")
                }.expectation {
                    exist("#txt_discard_title")
                }
            }
            scene(2, "編集を続ける") {
                action {
                    tap("#btn_keep")
                }.expectation {
                    notExist("#txt_discard_title")
                    select("#txt_screen_title").textIs("編集")
                    select("#field_title").valueIs("abc")
                }
            }
            scene(3, "システムの戻る → 破棄") {
                action {
                    android { hideKeyboard() }  // Android は IME が最初の back を消費する(iOS の Compose は閉じられない)
                    back()
                    tap("#btn_discard")
                }.expectation {
                    select("#txt_screen_title").textIs("戻るの横取り")
                    select("#txt_back_result").textIs("back=discarded")
                }
            }
        }
    }
}
