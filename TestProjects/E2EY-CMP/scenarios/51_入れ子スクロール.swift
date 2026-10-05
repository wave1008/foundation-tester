// 51_入れ子スクロール.swift
// 確かめる癖: 縦の一覧(LazyColumn)の中の横の一覧(LazyRow)。画面外のカードは木に居ない(仮想化)ので、縦の探索だけでは
// 届かず、行(#shelf_N)を scrollFrame に指して横へ探索する。

import FTDSL

@TestClass
class 縦の中の横の一覧のカードへ届くこと {

    @Test("段 7 の画面外のカードを横の探索で押す")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_nested", scroll: .down)
                }.expectation {
                    select("#txt_nested_result").textIs("nested=none")
                }
            }
            scene(2, "段 7 を縦の探索で画面に入れる") {
                action {
                    scrollTo("#shelf_7", scrollFrame: "#list_nested")
                }.expectation {
                    exist("#shelf_7")
                }
            }
            scene(3, "段 7 の横の探索でカード 12 を押す") {
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

    @Test("横へ送った段を左端まで戻し、別の段のカードも押せる")
    func S0020() {
        scenario {
            scene(1, "開いて段 0 を右の端まで送る") {
                condition {
                    launchApp()
                    tap("#nav_nested", scroll: .down)
                }.action {
                    scrollToRightEdge(scrollFrame: "#shelf_0")
                }.expectation {
                    exist("#card_0_14")
                }
            }
            scene(2, "左端まで戻すと先頭のカード") {
                action {
                    scrollToLeftEdge(scrollFrame: "#shelf_0")
                }.expectation {
                    exist("#card_0_00")
                }
            }
            scene(3, "段 1 のカード 05 へ横の探索で届く") {
                action {
                    withScrollRight(scrollFrame: "#shelf_1") {
                        tap("#card_1_05")
                    }
                }.expectation {
                    select("#txt_nested_result").textIs("nested=card_1_05")
                }
            }
        }
    }
}
