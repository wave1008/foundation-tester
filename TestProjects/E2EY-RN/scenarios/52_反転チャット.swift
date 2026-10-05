// 52_反転チャット.swift
// 確かめる癖: 反転したリスト(木の順と見た目の上下が逆・最初から最下部・「上へ送る」= 過去へ)。
// 着信は最下部なら追従・離れていれば位置を保つ。at_bottom はスクロールが止まった時点の値。

import FTDSL

@TestClass
class 反転チャットを過去へ送って最新へ戻れること {

    @Test("過去へ送ると最新へが出て、押すと最下部へ戻る")
    func S0010() {
        scenario {
            scene(1, "開く(最初から最下部)") {
                condition {
                    launchApp()
                    tap("#nav_chat", scroll: .down)
                }.expectation {
                    select("#txt_chat_pos").textIs("at_bottom=true")
                    select("#txt_chat_count").textIs("count=60")
                    exist("#msg_59")
                    notExist("#btn_jump_bottom")
                }
            }
            scene(2, "過去のメッセージを探索で押す(上へ送る)") {
                action {
                    withScrollUp(scrollFrame: "#list_chat") {
                        tap("#msg_30")
                    }
                }.expectation {
                    select("#txt_chat_result").textIs("chat=msg_30")
                    select("#txt_chat_pos").textIs("at_bottom=false", waitSeconds: 3)
                    exist("#btn_jump_bottom")
                }
            }
            scene(3, "最新へ") {
                action {
                    tap("#btn_jump_bottom")
                }.expectation {
                    select("#txt_chat_pos").textIs("at_bottom=true", waitSeconds: 5)
                    exist("#msg_59")
                }
            }
        }
    }

    @Test("送信した文字列が最下部に足される")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_chat", scroll: .down)
                }.expectation {
                    select("#txt_chat_count").textIs("count=60")
                }
            }
            scene(2, "入力して送信") {
                action {
                    type("#field_chat", "hello")
                    tap("#btn_send")
                }.expectation {
                    select("#txt_chat_count").textIs("count=61")
                    select("#msg_60").textIs("hello")
                    select("#txt_chat_pos").textIs("at_bottom=true", waitSeconds: 3)
                }
            }
        }
    }

    @Test("着信は最下部なら追従し、離れていれば位置を保つ")
    func S0030() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_chat", scroll: .down)
                }.expectation {
                    select("#txt_chat_pos").textIs("at_bottom=true")
                }
            }
            scene(2, "最下部で着信") {
                action {
                    tap("#btn_incoming")
                }.expectation {
                    select("#txt_chat_count").textIs("count=61", waitSeconds: 4)
                    exist("#msg_60")
                    select("#txt_chat_pos").textIs("at_bottom=true", waitSeconds: 3)
                }
            }
            scene(3, "離れて着信") {
                action {
                    withScrollUp(scrollFrame: "#list_chat") {
                        tap("#msg_20")
                    }
                    tap("#btn_incoming")
                }.expectation {
                    select("#txt_chat_count").textIs("count=62", waitSeconds: 4)
                    exist("#btn_jump_bottom")
                    select("#txt_chat_pos").textIs("at_bottom=false", waitSeconds: 3)
                }
            }
        }
    }
}
