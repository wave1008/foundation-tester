// 59_引き伸ばせるシート.swift
// 確かめる癖: 常駐のシート(BottomSheetScaffold)と背面の一覧が同時に操作できる・シートの中の探索のスワイプが
// 最初はシートの伸縮に吸われる(1回目は中身が動かない)。CMP は畳む(64dp)・半分(peekHeight 50%)・全開。

import FTDSL

@TestClass
class シートが畳まれていても背面を操作できること {

    @Test("畳んだ状態: 背面の行とミニプレーヤーのボタンを押せる")
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
            scene(2, "背面の行を押せる") {
                action {
                    tap("#row_main_02")
                }.expectation {
                    select("#txt_player_result").textIs("player=main:row_main_02")
                }
            }
            scene(3, "再生 ⇄ 一時停止") {
                action {
                    tap("#btn_mini_play")
                }.expectation {
                    select("#txt_player_result").textIs("player=play")
                    select("#btn_mini_play").textIs("一時停止")
                }.action {
                    tap("#btn_mini_play")
                }.expectation {
                    select("#txt_player_result").textIs("player=pause")
                }
            }
        }
    }

    @Test("ミニプレーヤーを押すと半分。半分からキューの下の行を探索で押すとシートが伸びる")
    func S0020() {
        scenario {
            scene(1, "ミニプレーヤーの本体を押す") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                }.action {
                    tap("#txt_mini_title")
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=half", waitSeconds: 5)
                    exist("#txt_player_title")
                }
            }
            scene(2, "キューの 21 行目を #list_queue の探索で押す") {
                action {
                    withScrollDown(scrollFrame: "#list_queue") {
                        tap("#queue_row_21")
                    }
                }.expectation {
                    select("#txt_player_result").textIs("player=queue:queue_row_21")
                    select("#txt_sheet_state").textIs("sheet=expanded")
                }
            }
            scene(3, "畳む") {
                action {
                    tap("#btn_player_collapse")
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=collapsed", waitSeconds: 5)
                }
            }
        }
    }

    @Test("ミニプレーヤーを上へ払うと伸びる")
    func S0030() {
        scenario {
            scene(1, "上へ払う") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                }.action {
                    swipeBy("#mini_player", dxRatio: 0, dyRatio: -6, durationSeconds: 0.4)
                }.expectation {
                    select("#txt_sheet_state").textMatches("^sheet=(half|expanded)$", waitSeconds: 5)
                }
            }
        }
    }
}
