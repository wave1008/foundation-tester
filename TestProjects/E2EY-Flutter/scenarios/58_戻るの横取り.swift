// 58_戻るの横取り.swift
// 確かめる癖: 戻るが遷移しないで終わる(パネルだけ閉じる)・戻るのあとに確認ダイアログが割り込む・
// OS で挙動が割れる(Flutter の PopScope は iOS で canPop=false の間エッジスワイプ自体を無効にする)。
// 戻るは両 OS で効く #btn_back を使う。

import FTDSL

@TestClass
class 戻るの横取りを扱えること {

    @Test("空の欄のまま戻ると、そのまま戻る")
    func S0010() {
        scenario {
            scene(1, "編集画面を開く") {
                condition {
                    launchApp()
                    tap("#nav_back_guard", scroll: .down)
                }.expectation {
                    select("#txt_back_result").textIs("back=none")
                }.action {
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

    @Test("パネルが開いていれば戻るはパネルだけを閉じる")
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
                    exist("#panel_inline")
                }
            }
            scene(2, "戻るとパネルだけ閉じて画面は戻らない") {
                action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_editor_state").textIs("panel=closed")
                    select("#txt_screen_title").textIs("編集")
                }
            }
        }
    }

    @Test("欄に文字があれば確認ダイアログ・続ける → 破棄")
    func S0030() {
        scenario {
            scene(1, "文字を入れて戻る") {
                condition {
                    launchApp()
                    tap("#nav_back_guard", scroll: .down)
                    tap("#btn_open_editor")
                }.action {
                    type("#field_title", "abc")
                    tap("#btn_back")
                }.expectation {
                    select("#txt_discard_title").textIs("変更を破棄しますか?")
                }
            }
            scene(2, "編集を続けると残り、値はそのまま") {
                action {
                    tap("#btn_keep")
                }.expectation {
                    select("#txt_screen_title").textIs("編集")
                    select("#field_title").valueIs("abc")
                }
            }
            scene(3, "もう一度戻って破棄") {
                action {
                    tap("#btn_back")
                    tap("#btn_discard")
                }.expectation {
                    select("#txt_screen_title").textIs("戻るの横取り")
                    select("#txt_back_result").textIs("back=discarded")
                }
            }
        }
    }

    @Test("Android のシステムの戻るでもパネルだけ閉じる")
    func S0040() {
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
                }
            }
            scene(2, "Android の戻る(iOS は #btn_back)") {
                action {
                    android {
                        back()
                    }
                    ios {
                        tap("#btn_back")
                    }
                }.expectation {
                    select("#txt_editor_state").textIs("panel=closed")
                    select("#txt_screen_title").textIs("編集")
                }
            }
        }
    }
}
