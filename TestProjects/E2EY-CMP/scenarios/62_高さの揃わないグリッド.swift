// 62_高さの揃わないグリッド.swift
// 確かめる癖: 木の並び順(タイル番号)と見た目の上下順が一致しない(列ごとに短い方へ詰める)。
// 「次の行」「末尾」の判定が普通のグリッドと違う。

import FTDSL

@TestClass
class 高さの揃わないグリッドのタイルへ届くこと {

    @Test("下の方のタイルへ探索で届き、先頭へ戻せる")
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
            scene(2, "47 番のタイル") {
                action {
                    tap("#stag_47", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_47")
                }
            }
            scene(3, "末尾のタイル") {
                action {
                    tap("#stag_59", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_59")
                }
            }
            scene(4, "先頭へ戻して 0 番のタイル") {
                action {
                    scrollToTop()
                    tap("#stag_00")
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_00")
                }
            }
        }
    }
}
