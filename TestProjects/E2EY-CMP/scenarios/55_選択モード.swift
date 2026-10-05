// 55_選択モード.swift
// 確かめる癖: 同じタップの意味がモードで変わる(通常 = 開く / 選択中 = 切り替え)・長押しで選択モードへ入る・
// 選択中だけアクションバーに置き換わる・同じ #id(#btn_edit)のラベルが 編集 ⇄ 完了 と変わる・選択状態の読み方。

import FTDSL

@TestClass
class 選択モードで行を選んで消せること {

    @Test("通常モードで行を押すと開く")
    func S0010() {
        scenario {
            scene(1, "行を押す") {
                condition {
                    launchApp()
                    tap("#nav_select", scroll: .down)
                }.action {
                    tap("#sel_row_05")
                }.expectation {
                    select("#txt_select_result").textIs("select=open:sel_row_05")
                    select("#txt_select_mode").textIs("mode=normal")
                }
            }
        }
    }

    @Test("長押しで選択モードへ入り、選んで削除")
    func S0020() {
        scenario {
            scene(1, "行を長押しすると選択モード") {
                condition {
                    launchApp()
                    tap("#nav_select", scroll: .down)
                }.action {
                    tap("#sel_row_05", holdSeconds: 1.0)
                }.expectation {
                    select("#txt_select_mode").textIs("mode=select")
                    select("#txt_select_count").textIs("selected=1")
                    select("#btn_edit").textIs("完了")
                    exist("#btn_sel_delete")
                    select("#sel_row_05").checkIsON()
                }
            }
            scene(2, "別の行を押すと選択に加わる(開かない)") {
                action {
                    tap("#sel_row_03")
                }.expectation {
                    select("#txt_select_count").textIs("selected=2")
                }
            }
            scene(3, "削除") {
                action {
                    tap("#btn_sel_delete")
                }.expectation {
                    select("#txt_select_result").textIs("select=deleted:03,05")
                    select("#txt_select_mode").textIs("mode=normal")
                    select("#btn_edit").textIs("編集")
                    notExist("#sel_row_05")
                }
            }
        }
    }

    @Test("編集ボタンで入り、すべて選択・キャンセル")
    func S0030() {
        scenario {
            scene(1, "編集を押すと何も選ばれていない選択モード") {
                condition {
                    launchApp()
                    tap("#nav_select", scroll: .down)
                }.action {
                    tap("#btn_edit")
                }.expectation {
                    select("#txt_select_mode").textIs("mode=select")
                    select("#txt_select_count").textIs("selected=0")
                    select("#btn_edit").textIs("完了")
                }
            }
            scene(2, "すべて選択") {
                action {
                    tap("#btn_sel_all")
                }.expectation {
                    select("#txt_select_count").textIs("selected=20")
                }
            }
            scene(3, "アイコンだけのキャンセルを #id で押す") {
                action {
                    tap("#btn_sel_cancel")
                }.expectation {
                    select("#txt_select_mode").textIs("mode=normal")
                    select("#txt_select_count").textIs("selected=0")
                }
            }
            scene(4, "完了でも抜けられる") {
                action {
                    tap("#btn_edit")
                    tap("#btn_edit")
                }.expectation {
                    select("#txt_select_mode").textIs("mode=normal")
                }
            }
        }
    }
}
