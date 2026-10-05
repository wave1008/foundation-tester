// 62_高さの揃わないグリッド.swift
// 確かめる癖: 木の順(列ごと: 左列 → 右列)と見た目の上下が一致しない・「末尾」の判定が普通のグリッドと違う
// (最後のタイルは左右どちらかの列の下端)。

import FTDSL

@TestClass
class 高さの揃わないグリッドを操作できること {

    @Test("中ほどと末尾のタイルを押す")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_staggered", scroll: .down)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=none")
                    exist("#stag_00")
                }
            }
            scene(2, "タイル 47 へ送って押す") {
                action {
                    tap("#stag_47", scroll: .down)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_47")
                }
            }
            scene(3, "末尾のタイル 59 へ送って押す") {
                action {
                    tap("#stag_59", scroll: .down)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_59")
                }
            }
        }
    }

    @Test("上へ戻って先頭のタイルを押す")
    func S0020() {
        scenario {
            scene(1, "末尾まで送って先頭へ戻る") {
                condition {
                    launchApp()
                    tap("#nav_staggered", scroll: .down)
                }.action {
                    scrollToBottom()
                    tap("#stag_01", scroll: .up)
                }.expectation {
                    select("#txt_staggered_result").textIs("stag=stag_01")
                }
            }
        }
    }
}
