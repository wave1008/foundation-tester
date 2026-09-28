// 37_FAB.swift
// 確かめる癖: リストの上に浮かぶ FAB と下のバー(浮かぶ部品が行を覆う・アイコンだけのボタン)。

import FTDSL

@TestClass
class FABと下のバーを操作できること {

    @Test("FAB・拡張 FAB・バーの操作")
    func S0010() {
        scenario {
            scene(1, "FAB") {
                condition {
                    launchApp()
                    tap("#nav_fab", scroll: .down)
                }.action {
                    tap("#fab_add")
                }.expectation {
                    select("#txt_fab_result").textIs("fab=add")
                }
            }
            scene(2, "拡張 FAB") {
                action {
                    tap("#fab_extended")
                }.expectation {
                    select("#txt_fab_result").textIs("fab=extended")
                }
            }
            scene(3, "バーの操作(#id とラベル)") {
                action {
                    tap("#bar_action_search")
                }.expectation {
                    select("#txt_fab_result").textIs("fab=search")
                }.action {
                    tap("共有")
                }.expectation {
                    select("#txt_fab_result").textIs("fab=share")
                }
            }
            scene(4, "FAB の下に潜った行へ届く") {
                action {
                    scrollTo("#row_f_29")
                }.expectation {
                    exist("#row_f_29")
                }
            }
        }
    }
}
