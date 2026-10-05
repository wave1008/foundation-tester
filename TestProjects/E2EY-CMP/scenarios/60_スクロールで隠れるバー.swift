// 60_スクロールで隠れるバー.swift
// 確かめる癖: 下へ送るとバー・FAB が隠れ(平行移動で画面外へ。木には居続ける)、少し戻すと現れる。
// 直前に送った向き次第で撃つ対象が画面外へ動いている。

import FTDSL

@TestClass
class 送りの向きでバーが隠れても扱えること {

    @Test("下へ送ると隠れ、上へ戻すと現れてバーのボタンを押せる")
    func S0010() {
        scenario {
            scene(1, "開く。バーが出ている") {
                condition {
                    launchApp()
                    tap("#nav_hide_bars", scroll: .down)
                }.expectation {
                    select("#txt_bars_state").textIs("bars=shown")
                    exist("#btn_bottom_a")
                }
            }
            scene(2, "探索で行を押す") {
                action {
                    tap("#row_h_33", scroll: .down, maxSwipes: 20)
                }.expectation {
                    select("#txt_hide_result").textIs("hide=row_h_33")
                }
            }
            scene(3, "最後に下へ送るとバーは隠れている") {
                action {
                    scrollDown()
                }.expectation {
                    select("#txt_bars_state").textIs("bars=hidden", waitSeconds: 5)
                }
            }
            scene(4, "上へ戻すとバーが現れ、下部バーのボタンを押せる") {
                action {
                    scrollToTop()
                }.expectation {
                    select("#txt_bars_state").textIs("bars=shown", waitSeconds: 5)
                }.action {
                    tap("#btn_bottom_b")
                }.expectation {
                    select("#txt_hide_result").textIs("hide=bottom_b")
                }
            }
            scene(5, "上部バーのボタンと FAB") {
                action {
                    tap("#btn_top_action")
                }.expectation {
                    select("#txt_hide_result").textIs("hide=top_action")
                }.action {
                    tap("#fab_hiding")
                }.expectation {
                    select("#txt_hide_result").textIs("hide=fab")
                }
            }
        }
    }
}
