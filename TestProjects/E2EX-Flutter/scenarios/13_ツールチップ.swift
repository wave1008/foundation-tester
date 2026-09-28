// 13_ツールチップ.swift
// 確かめる癖: TooltipBox(長押しで Popup = 別ウィンドウに出る・アンカーはアイコンだけ)。

import FTDSL

@TestClass
class ツールチップを出せること {

    // Flutter の Tooltip は指を離した後も showDuration(この SUT は 2 秒)だけ出ている = 両 OS で確かめられる
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
                    // Tooltip の本文には #id を付けられない(ラベルで指す)
                    exist("これはツールチップです")
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
