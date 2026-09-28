// 09_グリッド.swift
// 確かめる癖: LazyVerticalGrid(1行に3要素・画面外のセルは木に無い)。

import FTDSL

@TestClass
class グリッドを操作できること {

    @Test("下のセルへスクロール探索で届き、上端へ戻る")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_grid", scroll: .down)
                }.expectation {
                    select("#txt_grid_result").textIs("grid=none")
                    exist("#cell_00")
                }
            }
            scene(2, "右の列の下のセル") {
                action {
                    tap("#cell_86", scroll: .down)
                }.expectation {
                    select("#txt_grid_result").textIs("grid=86")
                }
            }
            scene(3, "真ん中の列のセルへ戻って押す") {
                action {
                    tap("#cell_46", scroll: .up)
                }.expectation {
                    select("#txt_grid_result").textIs("grid=46")
                }
            }
            scene(4, "上端") {
                action {
                    scrollToTop()
                    tap("#cell_00")
                }.expectation {
                    select("#txt_grid_result").textIs("grid=00")
                }
            }
        }
    }
}
