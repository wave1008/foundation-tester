// 54_スワイプの操作.swift
// 確かめる癖: 行の上の横の払い。払う距離で結果が変わる(途中まで = ボタンが出て止まる / 大半 = full swipe で
// 削除まで走る)・左から右はピン留め・返信行は閾値を越えて離すと元へ戻って echo だけ変わる。
// ボタンは払うまで操作できない。in-app は慣性を持たないのでエンジンで結果が割れうる。

import FTDSL

@TestClass
class 行を払ってボタンや返信を出せること {

    @Test("右から左へ途中まで払うとボタンが出て、アーカイブできる")
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
            scene(2, "途中まで払ってアーカイブ") {
                action {
                    swipeBy("#sw_row_1", dxRatio: -0.4, dyRatio: 0, durationSeconds: 0.5)
                    tap("#btn_sw_archive_1")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row1:archive")
                    select("#txt_swipe_actions_count").textIs("rows=6")
                }
            }
        }
    }

    @Test("途中まで払って削除ボタンを押すと行が消える")
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
            scene(2, "途中まで払って削除") {
                action {
                    swipeBy("#sw_row_2", dxRatio: -0.4, dyRatio: 0, durationSeconds: 0.5)
                    tap("#btn_sw_delete_2")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row2:delete")
                    select("#txt_swipe_actions_count").textIs("rows=5")
                }
            }
        }
    }

    @Test("行幅の大半まで払うとボタンを押さずに削除される(full swipe)")
    func S0030() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions", scroll: .down)
                }.expectation {
                    select("#txt_swipe_actions_count").textIs("rows=6")
                }
            }
            scene(2, "大きく払う") {
                action {
                    swipeBy("#sw_row_3", dxRatio: -0.9, dyRatio: 0, durationSeconds: 0.5)
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row3:delete")
                    select("#txt_swipe_actions_count").textIs("rows=5")
                }
            }
        }
    }

    @Test("左から右へ払うとピン留めが出る")
    func S0040() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions", scroll: .down)
                }.expectation {
                    select("#txt_swipe_actions_count").textIs("rows=6")
                }
            }
            scene(2, "左から右へ払ってピン留め") {
                action {
                    swipeBy("#sw_row_4", dxRatio: 0.3, dyRatio: 0, durationSeconds: 0.5)
                    tap("#btn_sw_pin_4")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row4:pin")
                }
            }
        }
    }

    @Test("返信行は閾値を越えて払うと元へ戻り、返信先だけが変わる")
    func S0050() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions", scroll: .down)
                }.expectation {
                    select("#txt_reply_target").textIs("reply=none")
                }
            }
            scene(2, "返信行を左から右へ払う") {
                action {
                    scrollTo("#reply_row_2")
                    swipeBy("#reply_row_2", dxRatio: 0.4, dyRatio: 0, durationSeconds: 0.5)
                }.expectation {
                    select("#txt_reply_target").textIs("reply=reply_row_2")
                    exist("#reply_row_2")
                }
            }
        }
    }
}
