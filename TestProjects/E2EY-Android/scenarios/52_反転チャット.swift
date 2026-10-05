// 52_反転チャット.swift
// 確かめる癖: LinearLayoutManager(reverseLayout = true)の RecyclerView。木の並びと見た目の上下が逆で、
// 最初から最下部(最新)に居る・上へ送る = 過去へ・離れている間だけ「最新へ」が出る・着信は最下部なら追従する。

import FTDSL

@TestClass
class 反転チャットを扱えること {

    @Test("最初は最下部に居て、最新のメッセージを押せる")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_chat", scroll: .down)
                }.expectation {
                    select("#txt_chat_pos").textIs("at_bottom=true")
                    select("#txt_chat_count").textIs("count=60")
                }
            }
            scene(2, "最新のメッセージ") {
                action {
                    tap("#msg_59")
                }.expectation {
                    select("#txt_chat_result").textIs("chat=msg_59")
                }
            }
        }
    }

    @Test("過去へ上に送って最古を押し、最新へで戻る")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_chat", scroll: .down)
                }.expectation {
                    select("#txt_chat_pos").textIs("at_bottom=true")
                }
            }
            scene(2, "最古のメッセージまで上へ送って押す") {
                action {
                    tap("#msg_00", scroll: .up, maxSwipes: 40)
                }.expectation {
                    select("#txt_chat_result").textIs("chat=msg_00")
                    select("#txt_chat_pos").textIs("at_bottom=false")
                }
            }
            scene(3, "最新へ") {
                action {
                    tap("#btn_jump_bottom")
                }.expectation {
                    select("#txt_chat_pos").textIs("at_bottom=true")
                    exist("#msg_59")
                }
            }
        }
    }

    @Test("送信したメッセージが最下部に載る")
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
                    select("#msg_60").textIs("hello")
                    select("#txt_chat_count").textIs("count=61")
                }
            }
        }
    }

    @Test("着信は最下部なら追従し、離れていれば位置を保つ")
    func S0040() {
        scenario {
            scene(1, "開く。最下部で着信") {
                condition {
                    launchApp()
                    tap("#nav_chat", scroll: .down)
                }.action {
                    tap("#btn_incoming")
                }.expectation {
                    select("#msg_60").textIs("着信 60")
                    select("#txt_chat_pos").textIs("at_bottom=true")
                }
            }
            scene(2, "過去へ離れてから着信") {
                action {
                    scrollTo("#msg_20", direction: .up)
                    tap("#btn_incoming")
                    wait(1.5)
                }.expectation {
                    select("#txt_chat_count").textIs("count=62")
                    select("#txt_chat_pos").textIs("at_bottom=false")
                    exist("#btn_jump_bottom")
                }
            }
            scene(3, "最新へ戻ると着信が見える") {
                action {
                    tap("#btn_jump_bottom")
                }.expectation {
                    select("#msg_61").textIs("着信 61")
                }
            }
        }
    }
}
