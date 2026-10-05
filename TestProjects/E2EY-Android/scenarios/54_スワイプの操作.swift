// 54_スワイプの操作.swift
// 確かめる癖: 払う距離で結果が変わる(途中まで = ボタンが出て止まる / 大半 = 確定して削除)・ボタンは払うまで
// 木に居ない・左から右の払い(ピン留め)・閾値を越えて離すと戻る返信の行(ItemTouchHelper)。

import FTDSL

@TestClass
class スワイプの操作を距離で使い分けられること {

    @Test("途中まで払うとアーカイブと削除のボタンが出て止まる")
    func S0010() {
        scenario {
            scene(1, "開く。ボタンはまだ木に居ない") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions", scroll: .down)
                }.expectation {
                    select("#txt_swipe_actions_count").textIs("rows=6")
                    notExist("#btn_sw_archive_3")
                }
            }
            scene(2, "3 行目を右から左へ途中まで払ってアーカイブ") {
                action {
                    swipeBy("#sw_row_3", dxRatio: -0.4, dyRatio: 0, durationSeconds: 0.4)
                }.expectation {
                    exist("#btn_sw_archive_3")
                    exist("#btn_sw_delete_3")
                }.action {
                    tap("#btn_sw_archive_3")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row3:archive")
                    select("#txt_swipe_actions_count").textIs("rows=6")
                }
            }
            scene(3, "別の行は削除ボタン") {
                action {
                    swipeBy("#sw_row_2", dxRatio: -0.4, dyRatio: 0, durationSeconds: 0.4)
                    tap("#btn_sw_delete_2")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row2:delete")
                    select("#txt_swipe_actions_count").textIs("rows=5")
                }
            }
        }
    }

    @Test("大半まで払うとボタンを押さずに削除まで走る(full swipe)")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions", scroll: .down)
                }.expectation {
                    select("#txt_swipe_actions_count").textIs("rows=6")
                }
            }
            scene(2, "4 行目を行幅の大半まで払う") {
                action {
                    swipeBy("#sw_row_4", dxRatio: -0.8, dyRatio: 0, durationSeconds: 0.4)
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row4:delete")
                    select("#txt_swipe_actions_count").textIs("rows=5")
                }
            }
        }
    }

    @Test("左から右へ払うとピン留めが出る")
    func S0030() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions", scroll: .down)
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=none")
                }
            }
            scene(2, "5 行目を左から右へ払ってピン留め") {
                action {
                    swipeBy("#sw_row_5", dxRatio: 0.4, dyRatio: 0, durationSeconds: 0.4)
                }.expectation {
                    exist("#btn_sw_pin_5")
                }.action {
                    tap("#btn_sw_pin_5")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row5:pin")
                }
            }
        }
    }

    @Test("ボタンが出た行は本体を押すと閉じる(action は変わらない)")
    func S0040() {
        scenario {
            scene(1, "開く。1 行目を払ってボタンを出す") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions", scroll: .down)
                }.action {
                    swipeBy("#sw_row_1", dxRatio: -0.4, dyRatio: 0, durationSeconds: 0.4)
                }.expectation {
                    exist("#btn_sw_delete_1")
                }
            }
            scene(2, "行の本体を押すと閉じる") {
                action {
                    tap("#sw_row_1")
                }.expectation {
                    notExist("#btn_sw_delete_1")
                    select("#txt_swipe_actions_result").textIs("action=none")
                }
            }
            scene(3, "閉じていれば本体を押すと開く動作") {
                action {
                    tap("#sw_row_1")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row1:open")
                }
            }
        }
    }

    @Test("返信の行は閾値を越えて離すと戻り、echo だけが変わる")
    func S0050() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions", scroll: .down)
                    scrollTo("#reply_row_2")
                }.expectation {
                    select("#txt_reply_target").textIs("reply=none")
                }
            }
            scene(2, "閾値に届かない払いでは何も起きない") {
                action {
                    swipeBy("#reply_row_1", dxRatio: 0.1, dyRatio: 0, durationSeconds: 0.4)
                    wait(1)
                }.expectation {
                    select("#txt_reply_target").textIs("reply=none")
                }
            }
            scene(3, "閾値を越えて離すと返信対象になり、行は消えない") {
                action {
                    swipeBy("#reply_row_2", dxRatio: 0.5, dyRatio: 0, durationSeconds: 0.4)
                }.expectation {
                    select("#txt_reply_target").textIs("reply=reply_row_2")
                    exist("#reply_row_2")
                    notExist("#btn_sw_archive_2")
                }
            }
        }
    }
}
