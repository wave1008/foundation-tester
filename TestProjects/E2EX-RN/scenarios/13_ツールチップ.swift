// 13_ツールチップ.swift
// 確かめる癖: TooltipBox(長押しで Popup = 別ウィンドウに出る・アンカーはアイコンだけ)。

import FTDSL

@TestClass
class ツールチップを出せること {

    // paper の Tooltip は押している間だけ出て、指を離すと消える。押している間に検証する(hold)
    @Test("アイコンを押している間だけツールチップが出る")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_tooltip", scroll: .down)
                }.expectation {
                    select("#txt_tooltip_state").textIs("tooltip=hidden")
                }
            }
            scene(2, "押している間は出て、離すと消える") {
                action {
                    hold("#btn_tooltip_anchor", holdSeconds: 3) {
                        select("#txt_tooltip").textIs("これはツールチップです")
                        select("#txt_tooltip_state").textIs("tooltip=shown")
                    }
                }.expectation {
                    select("#txt_tooltip_state").textIs("tooltip=hidden")
                }
            }
        }
    }

    @Test("アンカーをラベル(contentDescription)で長押し")
    func S0020() {
        scenario {
            scene(1, "ラベルで長押し") {
                condition {
                    launchApp()
                    tap("#nav_tooltip", scroll: .down)
                }.action {
                    tap("情報", holdSeconds: 1.0)
                }.expectation {
                    exist("これはツールチップです")
                }
            }
        }
    }
}
