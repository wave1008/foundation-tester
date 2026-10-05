// 52_反転チャット.swift
// 確かめる癖: 反転したリスト(木の順と見た目の上下が逆・最初から最下部 = 「上へ送る」が過去へ)・
// 最下部から離れている間だけ出る「最新へ」・着信が最下部なら追従、離れていれば位置を保つ。

import FTDSL

@TestClass
class 反転チャットを操作できること {

    @Test("最新から過去へ送り、最新へ戻る")
    func S0010() {
        scenario {
            scene(1, "開くと最下部に居る") {
                condition {
                    launchApp()
                    tap("#nav_chat", scroll: .down)
                }.expectation {
                    select("#txt_chat_count").textIs("count=60")
                    select("#txt_chat_pos").textIs("at_bottom=true")
                    exist("#msg_59")
                }
            }
            scene(2, "最新のメッセージを押す") {
                action {
                    tap("#msg_59")
                }.expectation {
                    select("#txt_chat_result").textIs("chat=msg_59")
                }
            }
            scene(3, "上へ送って過去のメッセージを押す") {
                action {
                    withScrollUp(scrollFrame: "#list_chat") {
                        tap("#msg_05")
                    }
                }.expectation {
                    select("#txt_chat_result").textIs("chat=msg_05")
                    select("#txt_chat_pos").textIs("at_bottom=false")
                    exist("#btn_jump_bottom")
                }
            }
            scene(4, "最新へ戻る(アニメーションあり)") {
                action {
                    tap("#btn_jump_bottom")
                }.expectation {
                    select("#txt_chat_pos").textIs("at_bottom=true", waitSeconds: 5)
                    exist("#msg_59")
                }
            }
        }
    }

    @Test("着信は最下部なら追従し、離れていれば位置を保つ")
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
            scene(2, "最下部で着信すると追従して見える") {
                action {
                    tap("#btn_incoming")
                }.expectation {
                    select("#txt_chat_count").textIs("count=61", waitSeconds: 5)
                    exist("#msg_60")
                    select("#txt_chat_pos").textIs("at_bottom=true")
                }
            }
            scene(3, "離れてから着信すると位置を保つ") {
                action {
                    withScrollUp(scrollFrame: "#list_chat") {
                        tap("#msg_20")
                    }
                    tap("#btn_incoming")
                }.expectation {
                    select("#txt_chat_count").textIs("count=62", waitSeconds: 5)
                    exist("#btn_jump_bottom")
                    select("#txt_chat_pos").textIs("at_bottom=false")
                }
            }
        }
    }

    @Test("送信した文字列が最下部に足される")
    func S0030() {
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
                    select("#txt_chat_pos").textIs("at_bottom=true")
                }
            }
        }
    }
}
