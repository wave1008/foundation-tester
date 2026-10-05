// 58_戻るの横取り.swift
// 確かめる癖: OnBackPressedDispatcher の常時有効なコールバック。戻るが遷移しないで終わる(パネルだけ閉じる)・
// 戻るのあとに確認ダイアログが割り込む。Android はキーボードが開いていると1回目の back が閉じるのに消費される
// ので、入力のあとは hideKeyboard() を挟む。

import FTDSL

@TestClass
class 戻るの横取りを扱えること {

    @Test("パネルが開いていれば戻るはパネルだけを閉じ、欄が空なら次の戻るで戻る")
    func S0010() {
        scenario {
            scene(1, "編集画面を開く") {
                condition {
                    launchApp()
                    tap("#nav_back_guard", scroll: .down)
                }.action {
                    tap("#btn_open_editor")
                }.expectation {
                    select("#txt_screen_title").textIs("編集")
                    select("#txt_editor_state").textIs("panel=closed")
                }
            }
            scene(2, "パネルを開く → 戻るで閉じるだけ") {
                action {
                    tap("#btn_open_panel")
                }.expectation {
                    select("#txt_editor_state").textIs("panel=open")
                }.action {
                    back()
                }.expectation {
                    select("#txt_editor_state").textIs("panel=closed")
                    select("#txt_screen_title").textIs("編集")
                }
            }
            scene(3, "欄が空なのでそのまま戻る") {
                action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("戻るの横取り")
                    select("#txt_back_result").textIs("back=clean")
                }
            }
        }
    }

    @Test("欄に文字があると確認ダイアログが割り込む(続ける → もう一度戻る → 破棄)")
    func S0020() {
        scenario {
            scene(1, "編集画面で文字を入れる") {
                condition {
                    launchApp()
                    tap("#nav_back_guard", scroll: .down)
                    tap("#btn_open_editor")
                }.action {
                    type("#field_title", "abc")
                    hideKeyboard()
                }.expectation {
                    select("#field_title").textIs("abc")
                }
            }
            scene(2, "戻るでダイアログが出る。編集を続ける") {
                action {
                    back()
                }.expectation {
                    select("#txt_discard_title").textIs("変更を破棄しますか?")
                }.action {
                    tap("#btn_keep")
                }.expectation {
                    select("#txt_screen_title").textIs("編集")
                    select("#field_title").textIs("abc")
                }
            }
            scene(3, "もう一度戻って破棄") {
                action {
                    back()
                    tap("#btn_discard")
                }.expectation {
                    select("#txt_screen_title").textIs("戻るの横取り")
                    select("#txt_back_result").textIs("back=discarded")
                }
            }
        }
    }

    @Test("アイコンだけの戻る(Toolbar)も同じコールバックを通る")
    func S0030() {
        scenario {
            scene(1, "パネルを開いてから Toolbar の戻る") {
                condition {
                    launchApp()
                    tap("#nav_back_guard", scroll: .down)
                    tap("#btn_open_editor")
                    tap("#btn_open_panel")
                }.action {
                    tap("戻る")
                }.expectation {
                    select("#txt_editor_state").textIs("panel=closed")
                    select("#txt_screen_title").textIs("編集")
                }
            }
            scene(2, "もう一度で戻る") {
                action {
                    tap("戻る")
                }.expectation {
                    select("#txt_back_result").textIs("back=clean")
                }
            }
        }
    }
}
