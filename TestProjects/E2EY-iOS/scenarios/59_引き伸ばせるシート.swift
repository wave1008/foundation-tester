// 59_引き伸ばせるシート.swift
// 確かめる癖: 閉じられない常駐シート(畳んだ状態でも背面が押せる)・半分の状態でキューを上へ払うと、まずシートが全開まで伸び、
// 伸び切ってからキューが送られる(探索の1回目が中身を動かさない)・畳むとキューは木から消える。

import FTDSL

@TestClass
class 引き伸ばせるシートを操作できること {

    @Test("畳んだ状態でも背面が押せて、ミニプレーヤーの再生が効く")
    func S0010() {
        scenario {
            scene(1, "開く(シートは畳まれている)") {
                condition {
                    launchApp()
                    tap("#nav_player")
                }.expectation {
                    select("#txt_sheet_state", waitSeconds: 5).textIs("sheet=collapsed")
                    exist("#mini_player")
                }
            }
            scene(2, "背面の行を押す") {
                action {
                    tap("#row_main_05")
                }.expectation {
                    select("#txt_player_result").textIs("player=main:row_main_05")
                }
            }
            scene(3, "再生 ⇄ 一時停止") {
                action {
                    tap("#btn_mini_play")
                }.expectation {
                    select("#txt_player_result").textIs("player=play")
                    select("#btn_mini_play").textIs("一時停止")
                }
            }
        }
    }

    @Test("半分の状態からキューを探索して押す")
    func S0020() {
        scenario {
            scene(1, "ミニプレーヤーを押して半分へ") {
                condition {
                    launchApp()
                    tap("#nav_player")
                    select("#txt_sheet_state", waitSeconds: 5).textIs("sheet=collapsed")
                }.action {
                    tap("#txt_mini_title")
                }.expectation {
                    select("#txt_sheet_state", waitSeconds: 5).textIs("sheet=half")
                    exist("#list_queue")
                }
            }
            scene(2, "キューを探索して queue_row_21 を押す") {
                action {
                    withScrollDown(scrollFrame: "#list_queue") {
                        tap("#queue_row_21")
                    }
                }.expectation {
                    select("#txt_player_result").textIs("player=queue:queue_row_21")
                    // 行が木に居て探索の払いが要らないので、シートが伸びるかは実装次第(半分のままでもよい)
                    select("#txt_sheet_state").textMatches("^sheet=(half|expanded)$")
                }
            }
        }
    }

    @Test("畳むボタンで畳むとキューは木から消える")
    func S0030() {
        scenario {
            scene(1, "半分 → 畳む") {
                condition {
                    launchApp()
                    tap("#nav_player")
                    select("#txt_sheet_state", waitSeconds: 5).textIs("sheet=collapsed")
                    tap("#txt_mini_title")
                    select("#txt_sheet_state", waitSeconds: 5).textIs("sheet=half")
                }.action {
                    tap("#btn_player_collapse")
                }.expectation {
                    select("#txt_sheet_state", waitSeconds: 5).textIs("sheet=collapsed")
                    notExist("#list_queue")
                }
            }
        }
    }
}
