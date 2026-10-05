// 51_入れ子スクロール.swift
// 確かめる癖: 縦の一覧の中の横の一覧(容器が2重)。段の画面外のカードは縦の探索だけでは届かず、
// 横の一覧(#shelf_N)を scrollFrame に指して横へ探索する。

import FTDSL

@TestClass
class 入れ子の横の一覧のカードへ届くこと {

    @Test("段 7 の画面外のカードを横の探索で押す")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_nested", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("入れ子スクロール")
                    select("#txt_nested_result").textIs("nested=none")
                }
            }
            scene(2, "縦の一覧を送って段 7 を出す") {
                action {
                    scrollTo("#txt_shelf_7", scrollFrame: "#list_nested")
                }.expectation {
                    exist("#shelf_7")
                }
            }
            scene(3, "段 7 の画面外のカードを横の探索で押す") {
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

    @Test("横の探索で右端まで行き、左端へ戻る")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_nested", scroll: .down)
                }.expectation {
                    select("#txt_nested_result").textIs("nested=none")
                }
            }
            scene(2, "段 0 の末尾のカード") {
                action {
                    withScrollRight(scrollFrame: "#shelf_0") {
                        tap("#card_0_14")
                    }
                }.expectation {
                    select("#txt_nested_result").textIs("nested=card_0_14")
                }
            }
            scene(3, "左端へ戻して先頭のカード") {
                action {
                    scrollToLeftEdge(scrollFrame: "#shelf_0")
                    tap("#card_0_00")
                }.expectation {
                    select("#txt_nested_result").textIs("nested=card_0_00")
                }
            }
        }
    }
}
