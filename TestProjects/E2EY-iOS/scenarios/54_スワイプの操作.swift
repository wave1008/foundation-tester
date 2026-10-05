// 54_スワイプの操作.swift
// 確かめる癖: 払う距離で結果が変わる(途中 = ボタンが出る・行幅の大半 = full swipe で即削除)・
// ボタンは払うまで木に居ない・左からのピン留め・自前 DragGesture の返信(閾値を越えて離すと元へ戻る)。

import FTDSL

@TestClass
class スワイプの操作を使い分けられること {

    @Test("途中まで払ってボタンを押す(アーカイブ → 削除)")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions")
                }.expectation {
                    select("#txt_swipe_actions_count").textIs("rows=6")
                    notExist("#btn_sw_archive_3")
                }
            }
            scene(2, "3行目を途中まで払ってアーカイブ") {
                action {
                    swipeBy("#sw_row_3", dxRatio: -0.4, dyRatio: 0, durationSeconds: 0.3)
                    tap("#btn_sw_archive_3", waitSeconds: 5)
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row3:archive")
                    select("#txt_swipe_actions_count").textIs("rows=6")
                }
            }
            scene(3, "2行目を途中まで払って削除ボタン") {
                action {
                    swipeBy("#sw_row_2", dxRatio: -0.4, dyRatio: 0, durationSeconds: 0.3)
                    tap("#btn_sw_delete_2", waitSeconds: 5)
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row2:delete")
                    select("#txt_swipe_actions_count").textIs("rows=5")
                }
            }
        }
    }

    @Test("行幅の大半まで払うとボタンを押さずに削除(full swipe)")
    func S0020() {
        scenario {
            scene(1, "4行目を大きく払う") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions")
                }.action {
                    swipeBy("#sw_row_4", dxRatio: -0.9, dyRatio: 0, durationSeconds: 0.3)
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row4:delete")
                    select("#txt_swipe_actions_count").textIs("rows=5")
                }
            }
        }
    }

    @Test("左から右へ払うとピン留め")
    func S0030() {
        scenario {
            scene(1, "1行目を左から右へ途中まで") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions")
                }.action {
                    swipeBy("#sw_row_1", dxRatio: 0.4, dyRatio: 0, durationSeconds: 0.3)
                    tap("#btn_sw_pin_1", waitSeconds: 5)
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row1:pin")
                }
            }
        }
    }

    @Test("返信行は閾値を越えて離すと返信になり、行は元へ戻る")
    func S0040() {
        scenario {
            scene(1, "返信行 2 を左から右へ") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions")
                }.action {
                    swipeBy("#reply_row_2", dxRatio: 0.45, dyRatio: 0, durationSeconds: 0.3)
                }.expectation {
                    select("#txt_reply_target").textIs("reply=reply_row_2")
                    exist("#reply_row_2")
                }
            }
        }
    }
}
