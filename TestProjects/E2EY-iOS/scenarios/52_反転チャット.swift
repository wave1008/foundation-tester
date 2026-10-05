// 52_反転チャット.swift
// 確かめる癖: UITableView を scaleY: -1 で反転した一覧(木の順と見た目の上下が逆)・入力バーが inputAccessoryView
// (キーボード側の別ウィンドウに居る #field_chat)・最下部に居るかで変わる着信の追従。

import FTDSL

@TestClass
class 反転したチャットを操作できること {

    @Test("最新から過去へ送って古いメッセージを押す")
    func S0010() {
        scenario {
            scene(1, "開くと最下部(最新が見えている)") {
                condition {
                    launchApp()
                    tap("#nav_chat")
                }.expectation {
                    select("#txt_chat_pos").textIs("at_bottom=true")
                    select("#txt_chat_count").textIs("count=60")
                    exist("#msg_59")
                }
            }
            scene(2, "過去へ送って msg_20 を押す") {
                action {
                    withScrollUp(scrollFrame: "#list_chat") {
                        tap("#msg_20")
                    }
                }.expectation {
                    select("#txt_chat_result").textIs("chat=msg_20")
                    select("#txt_chat_pos").textIs("at_bottom=false")
                }
            }
            scene(3, "最新へで最下部に戻る") {
                action {
                    tap("#btn_jump_bottom")
                }.expectation {
                    select("#txt_chat_pos").textIs("at_bottom=true", waitSeconds: 5)
                    notExist("#btn_jump_bottom")
                }
            }
        }
    }

    @Test("入力バー(inputAccessoryView)から送信して最下部に出る")
    func S0020() {
        scenario {
            scene(1, "送る") {
                condition {
                    launchApp()
                    tap("#nav_chat")
                }.action {
                    type("#field_chat", "hello")
                    tap("#btn_send")
                }.expectation {
                    select("#msg_60").textIs("hello")
                    select("#txt_chat_count").textIs("count=61")
                    select("#txt_chat_pos").textIs("at_bottom=true")
                }
            }
        }
    }

    @Test("着信は最下部なら追従・離れていれば位置を保つ")
    func S0030() {
        scenario {
            scene(1, "最下部で着信を受ける") {
                condition {
                    launchApp()
                    tap("#nav_chat")
                }.action {
                    tap("#btn_incoming")
                }.expectation {
                    select("#msg_60", waitSeconds: 5).textIs("着信 60")
                    select("#txt_chat_pos").textIs("at_bottom=true")
                }
            }
            scene(2, "過去へ離れて着信を受ける") {
                action {
                    scrollTo("#msg_30", direction: .up, scrollFrame: "#list_chat")
                    tap("#btn_incoming")
                    wait(2)
                }.expectation {
                    select("#txt_chat_count").textIs("count=62")
                    select("#txt_chat_pos").textIs("at_bottom=false")
                    exist("#btn_jump_bottom")
                }
            }
        }
    }
}
