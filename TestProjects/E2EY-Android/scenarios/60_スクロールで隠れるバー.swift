// 60_スクロールで隠れるバー.swift
// 確かめる癖: AppBarLayout(scroll|enterAlways)の上部バー・HideBottomViewOnScrollBehavior の下部バー・
// 自前 Behavior の FAB(hide() は消えきると GONE = 木から消える)。直前に送った向き次第で、撃つ対象が消えている。

import FTDSL

@TestClass
class スクロールで隠れるバーを扱えること {

    @Test("バーが出ている間は上部バー・FAB・下部バーを押せる")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_hide_bars", scroll: .down)
                }.expectation {
                    select("#txt_bars_state").textIs("bars=shown")
                    select("#txt_hide_result").textIs("hide=none")
                }
            }
            scene(2, "上部バーのアクション") {
                action {
                    tap("#btn_top_action")
                }.expectation {
                    select("#txt_hide_result").textIs("hide=top_action")
                }
            }
            scene(3, "FAB") {
                action {
                    tap("#fab_hiding")
                }.expectation {
                    select("#txt_hide_result").textIs("hide=fab")
                }
            }
            scene(4, "下部バー") {
                action {
                    tap("#btn_bottom_b")
                }.expectation {
                    select("#txt_hide_result").textIs("hide=bottom_b")
                }
            }
        }
    }

    @Test("下へ送るとバーが隠れ、少し戻すと現れる")
    func S0020() {
        scenario {
            scene(1, "開く。下へ送る") {
                condition {
                    launchApp()
                    tap("#nav_hide_bars", scroll: .down)
                }.action {
                    scrollDown(repeat: 2)
                }.expectation {
                    select("#txt_bars_state").textIs("bars=hidden")
                }
            }
            scene(2, "隠れている間は FAB が木に居ない") {
                expectation {
                    notExist("#fab_hiding", waitSeconds: 3)
                }
            }
            scene(3, "少し上へ送り返すと現れる") {
                action {
                    scrollUp()
                }.expectation {
                    select("#txt_bars_state").textIs("bars=shown")
                    exist("#fab_hiding")
                    exist("#btn_top_action")
                }
            }
        }
    }

    @Test("隠れた状態で届く行を押し、その向きのまま FAB を撃つ前に戻す")
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
            scene(2, "下の行を探索で押す(探索の向きでバーが隠れる)") {
                action {
                    tap("#row_h_33", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_hide_result").textIs("hide=row_h_33")
                }
            }
            scene(3, "FAB(隠れていれば上へ送って出す)") {
                action {
                    tap("#fab_hiding", scroll: .up)
                }.expectation {
                    select("#txt_hide_result").textIs("hide=fab")
                }
            }
        }
    }
}
