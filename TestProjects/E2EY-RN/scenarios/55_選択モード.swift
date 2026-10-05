// 55_選択モード.swift
// 確かめる癖: 同じタップの意味がモードで変わる(通常 = 開く / 選択 = 切り替え)・長押しで入る・
// 同じ #id のままラベルが変わる(編集 → 完了)・アクションバーに置き換わる。

import FTDSL

@TestClass
class 選択モードで行を選んで削除できること {

    @Test("通常モードでは行を押すと開く")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_select", scroll: .down)
                }.expectation {
                    select("#txt_select_mode").textIs("mode=normal")
                }
            }
            scene(2, "行を押す") {
                action {
                    tap("#sel_row_05")
                }.expectation {
                    select("#txt_select_result").textIs("select=open:sel_row_05")
                    select("#txt_select_mode").textIs("mode=normal")
                }
            }
        }
    }

    @Test("長押しで入り、2行選んで削除する")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_select", scroll: .down)
                }.expectation {
                    select("#txt_select_mode").textIs("mode=normal")
                }
            }
            scene(2, "行を長押しして選択モードへ") {
                action {
                    tap("#sel_row_05", holdSeconds: 1.0)
                }.expectation {
                    select("#txt_select_mode").textIs("mode=select")
                    select("#txt_select_count").textIs("selected=1")
                    select("#btn_edit").textIs("完了")
                }
            }
            scene(3, "もう1行を押して選ぶ(開かない)") {
                action {
                    tap("#sel_row_03")
                }.expectation {
                    select("#txt_select_count").textIs("selected=2")
                    select("#txt_select_result").textIs("select=none")
                }
            }
            scene(4, "削除") {
                action {
                    tap("#btn_sel_delete")
                }.expectation {
                    select("#txt_select_result").textIs("select=deleted:03,05")
                    select("#txt_select_mode").textIs("mode=normal")
                    notExist("#sel_row_03")
                }
            }
        }
    }

    @Test("編集で入り、すべて選択して完了で抜ける")
    func S0030() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_select", scroll: .down)
                }.expectation {
                    select("#btn_edit").textIs("編集")
                }
            }
            scene(2, "編集で入る(何も選ばれていない)") {
                action {
                    tap("#btn_edit")
                }.expectation {
                    select("#txt_select_mode").textIs("mode=select")
                    select("#txt_select_count").textIs("selected=0")
                }
            }
            scene(3, "すべて選択") {
                action {
                    tap("#btn_sel_all")
                }.expectation {
                    select("#txt_select_count").textIs("selected=20")
                }
            }
            scene(4, "完了で抜ける") {
                action {
                    tap("#btn_edit")
                }.expectation {
                    select("#txt_select_mode").textIs("mode=normal")
                    select("#txt_select_count").textIs("selected=0")
                    select("#btn_edit").textIs("編集")
                }
            }
        }
    }

    @Test("キャンセルで選択を捨てて抜ける")
    func S0040() {
        scenario {
            scene(1, "長押しで入る") {
                condition {
                    launchApp()
                    tap("#nav_select", scroll: .down)
                    tap("#sel_row_02", holdSeconds: 1.0)
                }.expectation {
                    select("#txt_select_count").textIs("selected=1")
                }
            }
            scene(2, "キャンセル") {
                action {
                    tap("#btn_sel_cancel")
                }.expectation {
                    select("#txt_select_mode").textIs("mode=normal")
                    select("#txt_select_count").textIs("selected=0")
                }
            }
        }
    }
}
