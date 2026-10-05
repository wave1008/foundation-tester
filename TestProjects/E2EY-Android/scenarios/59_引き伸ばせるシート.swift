// 59_引き伸ばせるシート.swift
// 確かめる癖: 常駐の BottomSheetBehavior(畳む・半分・全開)。畳んでいる間も背面が押せる・半分の状態でキューを
// 上へ払うと先にシートが伸びる(探索の1回目は中身が動かない)・シートが背面を覆わない。

import FTDSL

@TestClass
class 引き伸ばせるシートを操作できること {

    @Test("畳んだ状態でも背面の一覧が押せる")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=collapsed")
                    select("#txt_mini_title").textIs("再生中: トラック 1")
                }
            }
            scene(2, "背面の行") {
                action {
                    tap("#row_main_05")
                }.expectation {
                    select("#txt_player_result").textIs("player=main:row_main_05")
                    select("#txt_sheet_state").textIs("sheet=collapsed")
                }
            }
            scene(3, "再生と一時停止は同じ #id でラベルが変わる") {
                action {
                    tap("#btn_mini_play")
                }.expectation {
                    select("#txt_player_result").textIs("player=play")
                    select("#btn_mini_play").textIs("一時停止")
                }.action {
                    tap("#btn_mini_play")
                }.expectation {
                    select("#txt_player_result").textIs("player=pause")
                    select("#btn_mini_play").textIs("再生")
                }
            }
        }
    }

    @Test("ミニプレーヤーを押すと半分になり、畳むで戻る")
    func S0020() {
        scenario {
            scene(1, "開く。本体(ボタン以外)を押す") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                }.action {
                    tap("#txt_mini_title")
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=half")
                    exist("#txt_player_title")
                }
            }
            scene(2, "畳む") {
                action {
                    tap("#btn_player_collapse")
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=collapsed")
                }
            }
        }
    }

    @Test("半分の状態からキューを探索して押す(最初の送りはシートが伸びる)")
    func S0030() {
        scenario {
            scene(1, "半分にする") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                    tap("#txt_mini_title")
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=half")
                }
            }
            scene(2, "キューの探索で下の行へ") {
                action {
                    withScrollDown(scrollFrame: "#list_queue") {
                        tap("#queue_row_21")
                    }
                }.expectation {
                    select("#txt_player_result").textIs("player=queue:queue_row_21")
                    select("#txt_sheet_state").textIs("sheet=expanded")
                }
            }
        }
    }

    @Test("上へ払って開き、下へ払って縮める")
    func S0040() {
        scenario {
            scene(1, "ミニプレーヤーを上へ払う") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                }.action {
                    swipeBy("#txt_mini_title", dxRatio: 0, dyRatio: -0.9, durationSeconds: 0.4)
                }.expectation {
                    select("#txt_sheet_state").textMatches("^sheet=(half|expanded)$")
                }
            }
            scene(2, "畳むボタンで畳む") {
                action {
                    tap("#btn_player_collapse")
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=collapsed")
                }
            }
        }
    }
}
