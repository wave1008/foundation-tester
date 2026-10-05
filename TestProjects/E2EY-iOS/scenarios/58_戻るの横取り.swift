// 58_戻るの横取り.swift
// 確かめる癖: 戻るが遷移しないで終わる(パネルだけ閉じる)・戻るのあとにダイアログが割り込む・iOS のエッジスワイプ
// (独自の戻る #btn_back を持つ画面では back() はエッジスワイプに落ちる。docs/commands.md の back() の行)。

import FTDSL

@TestClass
class 戻る操作の横取りに対処できること {

    @Test("欄が空なら戻る(#btn_back)")
    func S0010() {
        scenario {
            scene(1, "編集画面を開いて戻る") {
                condition {
                    launchApp()
                    tap("#nav_back_guard")
                    tap("#btn_open_editor")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_back_result").textIs("back=clean")
                    select("#txt_screen_title").textIs("戻るの横取り")
                }
            }
        }
    }

    @Test("パネルが開いていれば戻るはパネルだけを閉じる")
    func S0020() {
        scenario {
            scene(1, "パネルを開いて戻る") {
                condition {
                    launchApp()
                    tap("#nav_back_guard")
                    tap("#btn_open_editor")
                }.action {
                    tap("#btn_open_panel")
                }.expectation {
                    select("#txt_editor_state").textIs("panel=open")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_editor_state").textIs("panel=closed")
                    select("#txt_screen_title").textIs("編集")
                }
            }
        }
    }

    @Test("欄に文字があれば破棄の確認が割り込む(続ける → 破棄)")
    func S0030() {
        scenario {
            scene(1, "打って戻る") {
                condition {
                    launchApp()
                    tap("#nav_back_guard")
                    tap("#btn_open_editor")
                }.action {
                    type("#field_title", "abc")
                    tap("#btn_back")
                }.expectation {
                    select("#txt_discard_title").textIs("変更を破棄しますか?")
                    select("#txt_screen_title").textIs("編集")
                }
            }
            scene(2, "編集を続ける") {
                action {
                    tap("#btn_keep")
                }.expectation {
                    notExist("#txt_discard_title")
                    select("#field_title").textIs("abc")
                }
            }
            scene(3, "もう一度戻って破棄") {
                action {
                    tap("#btn_back")
                    tap("#btn_discard")
                }.expectation {
                    select("#txt_back_result").textIs("back=discarded")
                    select("#txt_screen_title").textIs("戻るの横取り")
                }
            }
        }
    }

    @Test("エッジスワイプ(back())でも同じ判定を通る")
    func S0040() {
        scenario {
            scene(1, "欄に文字があるままエッジスワイプ") {
                condition {
                    launchApp()
                    tap("#nav_back_guard")
                    tap("#btn_open_editor")
                }.action {
                    type("#field_title", "abc")
                    back()
                }.expectation {
                    select("#txt_discard_title", waitSeconds: 5).textIs("変更を破棄しますか?")
                }
            }
            scene(2, "破棄して戻る") {
                action {
                    tap("#btn_discard")
                }.expectation {
                    select("#txt_back_result").textIs("back=discarded")
                }
            }
        }
    }
}
