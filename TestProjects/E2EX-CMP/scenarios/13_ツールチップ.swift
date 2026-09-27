// 13_ツールチップ.swift
// 確かめる癖: TooltipBox(長押しで Popup = 別ウィンドウに出る・アンカーはアイコンだけ)。

import FTDSL

@TestClass(platform: "ios")
class ツールチップを出せること {

    // Android の M3 ツールチップは押している間だけ出て、指を離すと消える(DSL は離してから検証する)。
    // 表示中も文字は別ウィンドウで木に載らない。なので iOS だけ
    @Test("アイコンを長押しするとツールチップが出る")
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
            scene(2, "#id で長押し") {
                action {
                    tap("#btn_tooltip_anchor", holdSeconds: 1.0)
                }.expectation {
                    select("#txt_tooltip").textIs("これはツールチップです")
                    select("#txt_tooltip_state").textIs("tooltip=shown")
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
