// 60_スクロールで隠れるバー.swift
// 確かめる癖: 直前に送った向き次第で撃つ対象が消えている・画面外へ動いている
// (下へ送ると上部バー・FAB・下部バーが隠れ、少しでも上へ送り返すと現れる)。

import FTDSL

@TestClass
class スクロールで隠れるバーを扱えること {

    @Test("下へ送ると隠れ、上へ送り返すと現れて押せる")
    func S0010() {
        scenario {
            scene(1, "開くとバーが出ていて押せる") {
                condition {
                    launchApp()
                    tap("#nav_hide_bars", scroll: .down)
                }.expectation {
                    select("#txt_bars_state").textIs("bars=shown")
                }.action {
                    tap("#fab_hiding")
                }.expectation {
                    select("#txt_hide_result").textIs("hide=fab")
                }
            }
            scene(2, "下へ送ると隠れる") {
                action {
                    scrollDown()
                }.expectation {
                    select("#txt_bars_state").textIs("bars=hidden", waitSeconds: 5)
                }
            }
            scene(3, "上へ送り返すと現れて下部バーのボタンを押せる") {
                action {
                    scrollUp()
                }.expectation {
                    select("#txt_bars_state").textIs("bars=shown", waitSeconds: 5)
                }.action {
                    tap("#btn_bottom_b")
                }.expectation {
                    select("#txt_hide_result").textIs("hide=bottom_b")
                }
            }
        }
    }

    @Draft("既知の制約: 上へ逃げたバーのボタンが木に残ったまま上のバーに覆われ、ツールが覆っている物を押す")
    @Test("下の行へ探索で届いたあと、隠れた上部バーのボタンを探索で押す")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_hide_bars", scroll: .down)
                }.expectation {
                    select("#txt_hide_result").textIs("hide=none")
                }
            }
            scene(2, "深い行を押す(探索の途中でバーは隠れる)") {
                action {
                    tap("#row_h_40", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_hide_result").textIs("hide=row_h_40")
                    select("#txt_bars_state").textIs("bars=hidden", waitSeconds: 5)
                }
            }
            scene(3, "上へ探索して上部バーのボタンを押す") {
                action {
                    tap("#btn_top_action", scroll: .up, maxSwipes: 30)
                }.expectation {
                    select("#txt_hide_result").textIs("hide=top_action")
                }
            }
        }
    }
}
