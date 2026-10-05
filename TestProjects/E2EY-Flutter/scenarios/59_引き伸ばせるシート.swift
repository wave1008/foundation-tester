// 59_引き伸ばせるシート.swift
// 確かめる癖: 背面とシートの両方が操作できる(シートの裏は覆われている、という前提が成り立たない)・
// 半分の状態でキューを上へ払うと、まずシートが全開まで伸び、伸び切ってからキューが送られる
// (探索の 1 回目が中身を動かさない)・シートの停止位置は止まった時点の値で読む。

import FTDSL

@TestClass
class 引き伸ばせるシートの背面と中身を操作できること {

    @Test("畳んだままでも背面の行とミニプレーヤーのボタンを押せる")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=collapsed")
                    select("#txt_player_result").textIs("player=none")
                }
            }
            scene(2, "背面の行を押す") {
                action {
                    tap("#row_main_05")
                }.expectation {
                    select("#txt_player_result").textIs("player=main:row_main_05")
                    select("#txt_sheet_state").textIs("sheet=collapsed")
                }
            }
            scene(3, "再生ボタン(押すと一時停止へ変わる)") {
                action {
                    tap("#btn_mini_play")
                }.expectation {
                    select("#txt_player_result").textIs("player=play")
                    select("#btn_mini_play").textIs("一時停止")
                }
            }
        }
    }

    @Test("半分から探索するとまずシートが全開まで伸びる")
    func S0020() {
        scenario {
            scene(1, "ミニプレーヤーの本体を押して半分にする") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                }.action {
                    tap("#txt_mini_title")
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=half", waitSeconds: 5)
                }
            }
            scene(2, "キューの深い行を探索で押す") {
                action {
                    withScrollDown(scrollFrame: "#list_queue") {
                        tap("#queue_row_21")
                    }
                }.expectation {
                    select("#txt_player_result").textIs("player=queue:queue_row_21")
                    select("#txt_sheet_state").textIs("sheet=expanded", waitSeconds: 5)
                }
            }
            scene(3, "畳むボタンで畳む") {
                action {
                    tap("#btn_player_collapse")
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=collapsed", waitSeconds: 5)
                }
            }
        }
    }

    @Test("ミニプレーヤーを上へ払うと半分か全開")
    func S0030() {
        scenario {
            scene(1, "上へ払う") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                }.action {
                    swipeElementToElement("#mini_player", "#txt_sheet_state", durationSeconds: 0.5)
                }.expectation {
                    select("#txt_sheet_state").textMatches("^sheet=(half|expanded)$", waitSeconds: 5)
                }
            }
        }
    }
}
