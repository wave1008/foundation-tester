// 60_スクロールで隠れるバー.swift
// 確かめる癖: 直前に送った向き次第で、撃つ対象(上部バー・FAB・下部バー)が消えている・画面外へ動いている。
// 下へ送ると隠れ、少しでも上へ送り返すと現れる。bars= は止まった時点の値。

import FTDSL

@TestClass
class スクロールで隠れるバーを出し入れして操作できること {

    @Draft("既知の制約: iOS で一覧に浮いた FAB をはみ出た要素とみなして一覧を送り、送った結果 FAB が隠れて見つからない")
    @Test("表示中のバーとFABの操作")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_hide_bars", scroll: .down)
                }.expectation {
                    select("#txt_bars_state").textIs("bars=shown")
                }
            }
            scene(2, "バーと FAB を押す") {
                action {
                    tap("#btn_top_action")
                }.expectation {
                    select("#txt_hide_result").textIs("hide=top_action")
                }.action {
                    tap("#fab_hiding")
                }.expectation {
                    select("#txt_hide_result").textIs("hide=fab")
                }.action {
                    tap("#btn_bottom_b")
                }.expectation {
                    select("#txt_hide_result").textIs("hide=bottom_b")
                }
            }
        }
    }

    @Test("下へ送るとバーが隠れ、上へ送り返すと現れて押せる")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_hide_bars", scroll: .down)
                }.expectation {
                    select("#txt_bars_state").textIs("bars=shown")
                }
            }
            scene(2, "下へ送る") {
                action {
                    scrollDown(repeat: 2)
                }.expectation {
                    select("#txt_bars_state").textIs("bars=hidden", waitSeconds: 3)
                }
            }
            scene(3, "少し上へ送り返す") {
                action {
                    scrollUp()
                }.expectation {
                    select("#txt_bars_state").textIs("bars=shown", waitSeconds: 3)
                }
            }
            scene(4, "現れた下部バーを押す") {
                action {
                    tap("#btn_bottom_a")
                }.expectation {
                    select("#txt_hide_result").textIs("hide=bottom_a")
                }
            }
        }
    }

    @Test("深い行へ探索で届いて押す")
    func S0030() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_hide_bars", scroll: .down)
                }.expectation {
                    select("#txt_bars_state").textIs("bars=shown")
                }
            }
            scene(2, "33 行目") {
                action {
                    tap("#row_h_33", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_hide_result").textIs("hide=row_h_33")
                }
            }
        }
    }
}
