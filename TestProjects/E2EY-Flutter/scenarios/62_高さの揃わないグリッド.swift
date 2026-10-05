// 62_高さの揃わないグリッド.swift
// 確かめる癖: 木の並び順(i の順)と見た目の上下順が一致しない(列ごとに短い方へ詰める)・
// 「次の行」「末尾」の判定が普通のグリッドと違う。

import FTDSL

@TestClass
class 高さの揃わないグリッドのタイルへ届くこと {

    @Test("先頭・深いタイル・末尾・先頭へ戻る")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_staggered", scroll: .down)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=none")
                }.action {
                    tap("#stag_00")
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_00")
                }
            }
            scene(2, "深いタイルを探索で押す") {
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
            scene(4, "上へ探索して先頭近くのタイル") {
                action {
                    tap("#stag_01", scroll: .up, maxSwipes: 30)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_01")
                }
            }
        }
    }
}
