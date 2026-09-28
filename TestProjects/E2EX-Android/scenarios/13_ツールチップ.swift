// 13_ツールチップ.swift
// 確かめる癖: TooltipBox(長押しで Popup = 別ウィンドウに出る・アンカーはアイコンだけ)。
// 押している間だけ出る部品なので、押している間に検証する(hold)。

import FTDSL

@TestClass
class ツールチップを出せること {

    @Test("アイコンを押している間にツールチップを確かめる")
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
            scene(2, "押している間は出ている") {
                action {
                    hold("#btn_tooltip_anchor", holdSeconds: 3) {
                        // 吹き出しは PopupWindow(フォーカスを取らない別ウィンドウ)で、文字は木に載らない。
                        // 出ていることは状態で確かめる
                        select("#txt_tooltip_state").textIs("tooltip=shown")
                    }
                }.expectation {
                    select("#txt_tooltip_state").textIs("tooltip=hidden")
                }
            }
        }
    }
}
