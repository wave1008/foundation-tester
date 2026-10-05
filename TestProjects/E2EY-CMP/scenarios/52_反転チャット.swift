// 52_反転チャット.swift
// 確かめる癖: reverseLayout の LazyColumn(木の順と見た目の上下が逆・最初から最下部 = 最新が見えている)。
// 「上へ送る」= 過去へ。着信は最下部に居れば追従し、離れていれば位置を保つ。

import FTDSL

@TestClass
class 反転チャットで過去と最新を行き来できること {

    @Test("最初は最下部。過去のメッセージを押し、最新へ戻る")
    func S0010() {
        scenario {
            scene(1, "開くと最新が見えている") {
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
            scene(3, "過去へ送ってメッセージ 30 を押す") {
                action {
                    tap("#msg_30", scroll: .up, maxSwipes: 20)
                }.expectation {
                    select("#txt_chat_result").textIs("chat=msg_30")
                    select("#txt_chat_pos").textIs("at_bottom=false")
                    exist("#btn_jump_bottom")
                }
            }
            scene(4, "最新へ") {
                action {
                    tap("#btn_jump_bottom")
                }.expectation {
                    select("#txt_chat_pos").textIs("at_bottom=true", waitSeconds: 5)
                    exist("#msg_59")
                }
            }
        }
    }

    @Draft("既知の制約: Compose(iOS in-app)の反転リストの探索は a11y の scroll が1ページ単位で飛ぶため、対象を容器の下端の外に置いたまま行き過ぎる(Android は緑)")
    @Test("着信: 最下部では追従し、離れていれば位置を保つ")
    func S0020() {
        scenario {
            scene(1, "最下部で着信を受ける") {
                condition {
                    launchApp()
                    tap("#nav_chat", scroll: .down)
                }.action {
                    tap("#btn_incoming")
                }.expectation {
                    select("#txt_chat_count").textIs("count=61", waitSeconds: 5)
                    select("#msg_60").textIs("着信 60", waitSeconds: 5)
                    select("#txt_chat_pos").textIs("at_bottom=true", waitSeconds: 5)
                }
            }
            scene(2, "過去へ離れて着信を受ける") {
                action {
                    scrollTo("#msg_40", direction: .up, scrollFrame: "#list_chat")
                    tap("#btn_incoming")
                }.expectation {
                    select("#txt_chat_count").textIs("count=62", waitSeconds: 5)
                    select("#txt_chat_pos").textIs("at_bottom=false")
                    exist("#btn_jump_bottom")
                }
            }
        }
    }

    @Test("入力バーから送ると最下部へ送られる")
    func S0030() {
        scenario {
            scene(1, "過去へ離れる") {
                condition {
                    launchApp()
                    tap("#nav_chat", scroll: .down)
                }.action {
                    scrollTo("#msg_20", direction: .up, scrollFrame: "#list_chat")
                }.expectation {
                    select("#txt_chat_pos").textIs("at_bottom=false")
                }
            }
            scene(2, "送信") {
                action {
                    type("#field_chat", "こんにちは")
                    tap("#btn_send")
                }.expectation {
                    select("#txt_chat_count").textIs("count=61")
                    select("#msg_60").textIs("こんにちは", waitSeconds: 5)
                    select("#txt_chat_pos").textIs("at_bottom=true", waitSeconds: 5)
                }
            }
        }
    }
}
