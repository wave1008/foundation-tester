// 54_スワイプの操作.swift
// 確かめる癖: 払う距離で結果が変わる(途中まで = ボタンが出て止まる / 行幅の大半 = 即削除 /
// 逆向き = ピン留め)・ボタンは払うまで押せない・自前ドラッグの返信は閾値(行幅の約 25%)で決まる。

import FTDSL

@TestClass
class スワイプの操作を撃ち分けられること {

    @Test("途中まで払うとボタンが出て、アーカイブと削除を押せる")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions", scroll: .down)
                }.expectation {
                    select("#txt_swipe_actions_count").textIs("rows=6")
                    select("#txt_swipe_actions_result").textIs("action=none")
                }
            }
            scene(2, "3 行目を右から左へ途中まで払ってアーカイブ") {
                action {
                    swipeBy("#sw_row_3", dxRatio: -0.4, dyRatio: 0, durationSeconds: 0.4)
                    tap("#btn_sw_archive_3")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row3:archive")
                    select("#txt_swipe_actions_count").textIs("rows=6")
                }
            }
            scene(3, "2 行目を途中まで払って削除ボタン") {
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

    @Test("行幅の大半まで払うとボタンを押さずに削除まで走る")
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
            scene(2, "4 行目を右端から左端近くまで払う(full swipe)") {
                action {
                    gesture("#sw_row_4") {
                        FTFinger(x: 0.95, y: 0.5).move(x: 0.05, y: 0.5, durationSeconds: 0.4)
                    }
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row4:delete", waitSeconds: 3)
                    select("#txt_swipe_actions_count").textIs("rows=5")
                }
            }
        }
    }

    @Test("左から右へ払うとピン留め・ボタンが出た行は本体を押すと閉じる")
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
            scene(2, "1 行目を左から右へ払ってピン留め") {
                action {
                    swipeBy("#sw_row_1", dxRatio: 0.3, dyRatio: 0, durationSeconds: 0.4)
                    tap("#btn_sw_pin_1")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row1:pin")
                }
            }
            scene(3, "ボタンが出た行の本体を押すと閉じるだけで action は変わらない") {
                action {
                    swipeBy("#sw_row_5", dxRatio: -0.4, dyRatio: 0, durationSeconds: 0.4)
                    tap("#sw_row_5")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row1:pin")
                }
            }
        }
    }

    @Test("返信行は閾値を越えて払うと返信・越えなければ何も起きない")
    func S0040() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions", scroll: .down)
                }.expectation {
                    select("#txt_reply_target").textIs("reply=none")
                }
            }
            scene(2, "短く払っても返信にならない") {
                action {
                    swipeBy("#reply_row_1", dxRatio: 0.1, dyRatio: 0, durationSeconds: 0.4, waitSeconds: 3)
                }.expectation {
                    select("#txt_reply_target").textIs("reply=none")
                }
            }
            scene(3, "閾値を越えて左から右へ払う") {
                action {
                    swipeBy("#reply_row_2", dxRatio: 0.5, dyRatio: 0, durationSeconds: 0.4)
                }.expectation {
                    select("#txt_reply_target").textIs("reply=reply_row_2")
                    exist("#reply_row_2")
                }
            }
        }
    }
}
