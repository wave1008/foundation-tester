// 62_高さの揃わないグリッド.swift
// 確かめる癖: StaggeredGridLayoutManager(2 列)。木の並び順(タイル番号順)と見た目の上下順が一致しない・
// 「次の行」「末尾」の判定が普通のグリッドと違う・列ごとに短い方へ詰める。

import FTDSL

@TestClass
class 高さの揃わないグリッドを扱えること {

    @Test("先頭のタイルを押す")
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
            scene(2, "最初のタイル") {
                action {
                    tap("#stag_00")
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_00")
                }
            }
        }
    }

    @Test("折り返しの下のタイルへ探索で届く")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_staggered", scroll: .down)
                }.expectation {
                    exist("#stag_00")
                }
            }
            scene(2, "47 番のタイル") {
                action {
                    tap("#stag_47", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_47")
                }
            }
        }
    }

    @Test("末尾のタイルまで届き、上端へ戻せる")
    func S0030() {
        scenario {
            scene(1, "開く。末尾のタイル") {
                condition {
                    launchApp()
                    tap("#nav_staggered", scroll: .down)
                }.action {
                    tap("#stag_59", scroll: .down, maxSwipes: 40)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_59")
                }
            }
            scene(2, "上端へ戻して先頭のタイル") {
                action {
                    scrollToTop()
                    tap("#stag_01")
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_01")
                }
            }
        }
    }
}
