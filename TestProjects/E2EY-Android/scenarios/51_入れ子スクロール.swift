// 51_入れ子スクロール.swift
// 確かめる癖: 縦の RecyclerView の中の横の RecyclerView(スクロール容器が2重)。横の画面外のカードは
// 仮想化で木に居ない。縦の探索だけでは届かず、段(#shelf_N)を scrollFrame に指して横へ送る。

import FTDSL

@TestClass
class 入れ子のスクロールの先のカードを押せること {

    @Test("画面内の段のカードを押す")
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
            scene(2, "最初の段の最初のカード") {
                action {
                    tap("#card_0_00")
                }.expectation {
                    select("#txt_nested_result").textIs("nested=card_0_00")
                }
            }
        }
    }

    @Test("折り返しの下の段へ縦に送り、その段を横に送って画面外のカードを押す")
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
            scene(2, "段 7 まで縦に送る(縦の容器は一覧)") {
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

    @Test("別の段でも横の探索は自分の段だけを送る")
    func S0030() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_nested", scroll: .down)
                }.expectation {
                    select("#txt_nested_result").textIs("nested=none")
                }
            }
            scene(2, "段 1 の末尾のカード") {
                action {
                    withScrollRight(scrollFrame: "#shelf_1") {
                        tap("#card_1_14")
                    }
                }.expectation {
                    select("#txt_nested_result").textIs("nested=card_1_14")
                }
            }
            scene(3, "段 0 のカードは動いていない") {
                expectation {
                    exist("#card_0_00")
                }
            }
        }
    }
}
