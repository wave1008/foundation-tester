// 33_ダイアログ.swift
// 確かめる癖: アラート・入力欄つきダイアログ・アクションシート・全画面ダイアログ(どれも別ウィンドウ/モーダル)。

import FTDSL

@TestClass
class ダイアログの変種を操作できること {

    @Test("アラートの OK とキャンセル")
    func S0010() {
        scenario {
            scene(1, "OK") {
                condition {
                    launchApp()
                    tap("#nav_dialogs", scroll: .down)
                }.action {
                    tap("#btn_alert")
                    tap("OK")
                }.expectation {
                    select("#txt_dialogs_result").textIs("alert=ok")
                }
            }
            scene(2, "キャンセル") {
                action {
                    tap("#btn_alert")
                    tap("キャンセル")
                }.expectation {
                    select("#txt_dialogs_result").textIs("alert=cancel")
                }
            }
        }
    }

    @Test("入力欄つきダイアログに入力して保存")
    func S0020() {
        scenario {
            scene(1, "入力して保存") {
                condition {
                    launchApp()
                    tap("#nav_dialogs", scroll: .down)
                }.action {
                    tap("#btn_prompt")
                    // .alert の TextField は in-app の木に載らない(焦点は欄にある)ので、欄を指さずに打つ
                    type("abc")
                    tap("保存")
                }.expectation {
                    select("#txt_dialogs_result").textIs("prompt=abc")
                }
            }
        }
    }

    @Test("アクションシートで選ぶ")
    func S0030() {
        scenario {
            scene(1, "ライブラリから選ぶ") {
                condition {
                    launchApp()
                    tap("#nav_dialogs", scroll: .down)
                }.action {
                    tap("#btn_action_sheet")
                    tap("ライブラリから選ぶ")
                }.expectation {
                    select("#txt_dialogs_result").textIs("sheet=library")
                }
            }
        }
    }

    @Test("全画面ダイアログで保存")
    func S0040() {
        scenario {
            scene(1, "保存") {
                condition {
                    launchApp()
                    tap("#nav_dialogs", scroll: .down)
                }.action {
                    tap("#btn_fullscreen")
                    exist("#txt_fullscreen_title")
                    tap("#btn_fullscreen_save")
                }.expectation {
                    select("#txt_dialogs_result").textIs("fullscreen=saved")
                    notExist("#txt_fullscreen_title")
                }
            }
        }
    }
}
