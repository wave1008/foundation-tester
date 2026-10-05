// 51_入れ子スクロール.swift
// 確かめる癖: 縦の一覧の中の横の一覧(スクロール容器が2重)。画面外のカードは縦の探索では届かず、
// 行 #shelf_7 を scrollFrame に指した横の探索が要る。

import FTDSL

@TestClass
class 入れ子の横の一覧の画面外のカードへ届くこと {

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
            scene(2, "段 7 を画面へ入れる(縦の探索)") {
                action {
                    scrollTo("#shelf_7")
                }.expectation {
                    exist("#shelf_7")
                }
            }
            scene(3, "段 7 の 13 枚目を横の探索で押す") {
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

    @Test("横に送った段を縦に戻っても別の段の先頭が押せる")
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
            scene(2, "段 0 の先頭のカード") {
                action {
                    tap("#card_0_00")
                }.expectation {
                    select("#txt_nested_result").textIs("nested=card_0_00")
                }
            }
            scene(3, "段 5 を横に送って端のカード") {
                action {
                    scrollTo("#shelf_5")
                    withScrollRight(scrollFrame: "#shelf_5") {
                        tap("#card_5_14")
                    }
                }.expectation {
                    select("#txt_nested_result").textIs("nested=card_5_14")
                }
            }
        }
    }
}
