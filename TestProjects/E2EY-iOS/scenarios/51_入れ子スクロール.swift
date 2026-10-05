// 51_入れ子スクロール.swift
// 確かめる癖: 縦の List の中の横 ScrollView。段 7 は折り返しの下、その中のカード 12 は横の画面外。
// 縦の探索だけでは届かず、横の行(#shelf_7)を scrollFrame に指す必要がある。

import FTDSL

@TestClass
class 入れ子のスクロールで画面外のカードを押せること {

    @Test("段 7 のカード 12 を横の探索で押す")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_nested")
                }.expectation {
                    select("#txt_nested_result").textIs("nested=none")
                }
            }
            scene(2, "縦に送って段 7 を出す") {
                action {
                    scrollTo("#txt_shelf_7")
                }.expectation {
                    exist("#shelf_7")
                }
            }
            scene(3, "段 7 を横に送ってカード 12 を押す") {
                action {
                    withScrollRight(scrollFrame: "#shelf_7") {
                        tap("#card_7_12")
                    }
                }.expectation {
                    select("#txt_nested_result").textIs("nested=card_7_12")
                }
            }
        }
    }

    @Test("横の探索のあと縦の探索で別の段へ")
    func S0020() {
        scenario {
            scene(1, "段 9 のカード 14(末尾)") {
                condition {
                    launchApp()
                    tap("#nav_nested")
                }.action {
                    scrollTo("#txt_shelf_9")
                    // 段の幅 370pt を1本 222pt で送るので、末尾(カード 14)には既定の 8 本では届かない
                    withScrollRight(scrollFrame: "#shelf_9") {
                        tap("#card_9_14", maxSwipes: 12)
                    }
                }.expectation {
                    select("#txt_nested_result").textIs("nested=card_9_14")
                }
            }
            scene(2, "段 8 のカード 05") {
                action {
                    scrollTo("#txt_shelf_8", direction: .up)
                    withScrollRight(scrollFrame: "#shelf_8") {
                        tap("#card_8_05")
                    }
                }.expectation {
                    select("#txt_nested_result").textIs("nested=card_8_05")
                }
            }
        }
    }
}
