// 54_スワイプの操作.swift
// 確かめる癖: 払う距離で結果が変わる(途中まで = ボタンが出て止まる / 大半 = ボタンを押さずに削除まで走る)・
// 払うまでボタンが木に居ない・スワイプで返信(閾値を越えて離すと元へ戻り、行は消えない)。
// 途中まで払うのはゆっくり(2 秒): 速く離すと AnchoredDraggable の fling が次のアンカー(削除)まで送る
// (XCUITest の払いは離す速度を持つ。0.4 秒では iOS で削除まで走った)。

import FTDSL

@TestClass
class スワイプの距離で結果が変わること {

    @Test("右から左へ途中まで払うとボタンが出る")
    func S0010() {
        scenario {
            scene(1, "開く。払うまで行のボタンは無い") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions", scroll: .down)
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=none")
                    select("#txt_swipe_actions_count").textIs("rows=6")
                    notExist("#btn_sw_archive_3")
                }
            }
            scene(2, "3 行目を途中まで払ってアーカイブ") {
                action {
                    swipeBy("#sw_row_3", dxRatio: -0.45, dyRatio: 0, durationSeconds: 2.0)
                }.expectation {
                    exist("#btn_sw_archive_3")
                }.action {
                    tap("#btn_sw_archive_3")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row3:archive")
                }
            }
            scene(3, "2 行目を途中まで払って削除ボタン") {
                action {
                    swipeBy("#sw_row_2", dxRatio: -0.45, dyRatio: 0, durationSeconds: 2.0)
                    tap("#btn_sw_delete_2")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row2:delete")
                    select("#txt_swipe_actions_count").textIs("rows=5")
                }
            }
        }
    }

    @Test("大半まで払うと(full swipe)ボタンを押さずに削除まで走る")
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
                    swipeBy("#sw_row_4", dxRatio: -0.9, dyRatio: 0, durationSeconds: 0.4)
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row4:delete", waitSeconds: 5)
                    select("#txt_swipe_actions_count").textIs("rows=5")
                }
            }
        }
    }

    @Test("左から右へ途中まで払うとピン留め")
    func S0030() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions", scroll: .down)
                }.expectation {
                    notExist("#btn_sw_pin_1")
                }
            }
            scene(2, "1 行目を左から右へ途中まで払ってピン留め") {
                action {
                    swipeBy("#sw_row_1", dxRatio: 0.3, dyRatio: 0, durationSeconds: 2.0)
                }.expectation {
                    exist("#btn_sw_pin_1")
                }.action {
                    tap("#btn_sw_pin_1")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=row1:pin")
                }
            }
        }
    }

    @Test("ボタンが出た行は本体を押すと閉じ(action は変わらない)、返信は閾値を越えて離すと元へ戻る")
    func S0040() {
        scenario {
            scene(1, "5 行目を払って開いたまま本体を押す") {
                condition {
                    launchApp()
                    tap("#nav_swipe_actions", scroll: .down)
                }.action {
                    swipeBy("#sw_row_5", dxRatio: -0.45, dyRatio: 0, durationSeconds: 2.0)
                    tap("#sw_row_5")
                }.expectation {
                    select("#txt_swipe_actions_result").textIs("action=none")
                }
            }
            scene(2, "返信行 2 を左から右へ払う") {
                action {
                    swipeBy("#reply_row_2", dxRatio: 0.4, dyRatio: 0, durationSeconds: 0.4)
                }.expectation {
                    select("#txt_reply_target").textIs("reply=reply_row_2", waitSeconds: 3)
                    exist("#reply_row_2")
                    select("#txt_swipe_actions_count").textIs("rows=6")
                }
            }
        }
    }
}
