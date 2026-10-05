// 60_スクロールで隠れるバー.swift
// 確かめる癖: 下へ送るとバー・FAB が隠れ(木から消える・画面外へ動く)、少しでも戻すと現れる。
// 直前に送った向き次第で、撃つ対象が消えている。

import FTDSL

@TestClass
class スクロールで隠れるバーを扱えること {

    @Test("下へ送ると隠れ、戻すと現れて押せる")
    func S0010() {
        scenario {
            scene(1, "開く(バーが出ている)") {
                condition {
                    launchApp()
                    tap("#nav_hide_bars")
                }.action {
                    tap("#btn_top_action")
                }.expectation {
                    select("#txt_bars_state").textIs("bars=shown")
                    select("#txt_hide_result").textIs("hide=top_action")
                }
            }
            scene(2, "下へ送るとバーが隠れる") {
                action {
                    scrollDown()
                }.expectation {
                    select("#txt_bars_state", waitSeconds: 3).textIs("bars=hidden")
                    notExist("#fab_hiding")
                }
            }
            scene(3, "少し戻すと現れる") {
                action {
                    scrollUp()
                }.expectation {
                    select("#txt_bars_state", waitSeconds: 3).textIs("bars=shown")
                    exist("#fab_hiding")
                }
            }
            scene(4, "FAB と下部バーを押す") {
                action {
                    tap("#fab_hiding")
                    tap("#btn_bottom_b")
                }.expectation {
                    select("#txt_hide_result").textIs("hide=bottom_b")
                }
            }
        }
    }

    @Test("深い行へ送ったあと、行を押す")
    func S0020() {
        scenario {
            scene(1, "行 33 まで送って押す") {
                condition {
                    launchApp()
                    tap("#nav_hide_bars")
                }.action {
                    tap("#row_h_33", scroll: .down)
                }.expectation {
                    select("#txt_hide_result").textIs("hide=row_h_33")
                }
            }
        }
    }
}
