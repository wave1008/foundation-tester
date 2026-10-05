// 59_引き伸ばせるシート.swift
// 確かめる癖: 常駐の非モーダルシート(畳む・半分・全開の三段)。背面も操作できる(シートの裏は覆われている、
// という前提が成り立たない)。半分の状態でキューを上へ払うと、まずシートが全開まで伸び、そのあとでキューが送られる
// (探索の1回目が吸われる)。

import FTDSL

@TestClass
class 引き伸ばせるシートの中と背面を操作できること {

    @Test("畳んだ状態でも背面の行とミニプレーヤーの再生が押せる")
    func S0010() {
        scenario {
            scene(1, "開く(畳んだ状態)") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=collapsed")
                    select("#txt_mini_title").textIs("再生中: トラック 1")
                }
            }
            scene(2, "背面の行を押す") {
                action {
                    tap("#row_main_02")
                }.expectation {
                    select("#txt_player_result").textIs("player=main:row_main_02")
                }
            }
            scene(3, "再生") {
                action {
                    tap("#btn_mini_play")
                }.expectation {
                    select("#txt_player_result").textIs("player=play")
                    exist("一時停止")
                }.action {
                    tap("#btn_mini_play")
                }.expectation {
                    select("#txt_player_result").textIs("player=pause")
                }
            }
        }
    }

    @Test("ミニプレーヤーを押すと半分になり、半分からキューの奥へ探索で届く", platform: "android")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=collapsed")
                }
            }
            scene(2, "ミニプレーヤーを押して半分へ") {
                action {
                    tap("#mini_player")
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=half", waitSeconds: 3)
                    exist("#txt_player_title")
                }
            }
            scene(3, "キューの奥の行を探索で押す(1回目はシートの伸長に吸われる)") {
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

    @Draft("既知の制約: iOS では半分の gorhom のシートが一覧の上からの払いで伸びない(XCUITest の本物の払いでも in-app でも同じ。見出しからの払いなら伸びる)。木にグラバーが出ないので、探索は伸ばす場所を決められない")
    @Test("ミニプレーヤーを押すと半分になり、半分からキューの奥へ探索で届く(iOS)", platform: "ios")
    func S0021() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=collapsed")
                }
            }
            scene(2, "ミニプレーヤーを押して半分へ") {
                action {
                    tap("#mini_player")
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=half", waitSeconds: 3)
                    exist("#txt_player_title")
                }
            }
            scene(3, "キューの奥の行を探索で押す(1回目はシートの伸長に吸われる)") {
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

    @Test("全開から畳むで畳まれる")
    func S0030() {
        scenario {
            scene(1, "半分へ") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                    tap("#mini_player")
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=half", waitSeconds: 3)
                }
            }
            scene(2, "畳む") {
                action {
                    tap("#btn_player_collapse")
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=collapsed", waitSeconds: 3)
                    exist("#mini_player")
                }
            }
        }
    }

    @Test("ミニプレーヤーを上へ払うと半分か全開になる")
    func S0040() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_player", scroll: .down)
                }.expectation {
                    select("#txt_sheet_state").textIs("sheet=collapsed")
                }
            }
            scene(2, "上へ払う") {
                action {
                    swipeElementToElement("#mini_player", "#txt_sheet_state", durationSeconds: 0.5)
                }.expectation {
                    select("#txt_sheet_state").textMatches("^sheet=(half|expanded)$", waitSeconds: 3)
                }
            }
        }
    }
}
