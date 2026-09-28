// 34_長押しメニュー.swift
// 確かめる癖: 長押しで開くコンテキストメニュー(長押しの保持時間・メニューは別ウィンドウ)。

import FTDSL

@TestClass
class 長押しメニューを操作できること {

    @Test("行を長押しして複製")
    func S0010() {
        scenario {
            scene(1, "長押しして選ぶ") {
                condition {
                    launchApp()
                    tap("#nav_context", scroll: .down)
                }.action {
                    tap("#ctx_row_2", holdSeconds: 1.0)
                    tap("複製")
                }.expectation {
                    select("#txt_context_result").textIs("context=row2:copy")
                }
            }
        }
    }
}
