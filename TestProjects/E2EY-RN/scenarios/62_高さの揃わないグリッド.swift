// 62_高さの揃わないグリッド.swift
// 確かめる癖: 2 列の masonry(FlashList)。木の並び順(i の順)と見た目の上下順が一致しない
// (列ごとに短い方へ詰める)ので「次の行」「末尾」の判定が普通のグリッドと違う。仮想化もある。

import FTDSL

@TestClass
class 高さの揃わないグリッドのタイルを押せること {

    @Test("先頭の 2 枚を押す")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_staggered", scroll: .down)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=none")
                }
            }
            scene(2, "先頭") {
                action {
                    tap("#stag_00")
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_00")
                }.action {
                    tap("#stag_01")
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_01")
                }
            }
        }
    }

    @Test("奥のタイルへ探索で届く")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_staggered", scroll: .down)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=none")
                }
            }
            scene(2, "47 枚目") {
                action {
                    tap("#stag_47", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_47")
                }
            }
            scene(3, "末尾の 59 枚目") {
                action {
                    tap("#stag_59", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_59")
                }
            }
        }
    }
}
