// 58_戻るの横取り.swift
// 確かめる癖: 戻る(システムの戻る・iOS はエッジスワイプ)が遷移しないで終わる(パネルを閉じるだけ)・
// 戻るのあとに確認ダイアログが割り込む(欄に文字がある間)。OS で挙動が割れる。
// usePreventRemove: パネル開 or 欄に文字がある間だけ横取りする(native-stack はその間エッジスワイプも止める)。

import FTDSL

@TestClass
class 戻るを横取りされても期待どおりに戻れること {

    @Test("何も触らずに戻ると back=clean")
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
                    back()
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
                    tap("#btn_open_panel")
                }.expectation {
                    select("#txt_editor_state").textIs("panel=open")
                }
            }
            scene(2, "戻るでパネルだけ閉じる") {
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

    @Test("文字を入れて戻ると確認が出て、破棄すると戻る")
    func S0030() {
        scenario {
            scene(1, "文字を入れる") {
                condition {
                    launchApp()
                    tap("#nav_back_guard", scroll: .down)
                    tap("#btn_open_editor")
                    type("#field_title", "abc")
                }.expectation {
                    select("#field_title").valueIs("abc")
                }
            }
            scene(2, "戻ると確認が割り込む") {
                action {
                    // Android は開いたキーボードが最初の戻るを受けるので、先に閉じる
                    android { hideKeyboard() }
                    back()
                }.expectation {
                    select("#txt_discard_title").textIs("変更を破棄しますか?")
                    select("#txt_screen_title").textIs("編集")
                }
            }
            scene(3, "破棄") {
                action {
                    tap("#btn_discard")
                }.expectation {
                    select("#txt_screen_title").textIs("戻るの横取り")
                    select("#txt_back_result").textIs("back=discarded")
                }
            }
        }
    }

    @Test("編集を続けると欄の値はそのまま")
    func S0040() {
        scenario {
            scene(1, "文字を入れて戻る") {
                condition {
                    launchApp()
                    tap("#nav_back_guard", scroll: .down)
                    tap("#btn_open_editor")
                    type("#field_title", "xyz")
                    android { hideKeyboard() }
                    back()
                }.expectation {
                    exist("#btn_keep")
                }
            }
            scene(2, "編集を続ける") {
                action {
                    tap("#btn_keep")
                }.expectation {
                    select("#txt_screen_title").textIs("編集")
                    select("#field_title").valueIs("xyz")
                    notExist("#txt_discard_title")
                }
            }
        }
    }
}
