// 55_選択モード.swift
// 確かめる癖: 同じタップの意味がモードで変わる(開く ⇄ 選択の切り替え)・行の長押しで選択モードに入る・
// 同一 #id のままラベルが変わる #btn_edit(編集 ⇄ 完了)・List(selection:) の標準の選択状態。

import FTDSL

@TestClass
class 選択モードを操作できること {

    @Test("通常モードで押すと開き、長押しで選択モードへ入る")
    func S0010() {
        scenario {
            scene(1, "通常モードで押す") {
                condition {
                    launchApp()
                    tap("#nav_select")
                }.action {
                    tap("#sel_row_05")
                }.expectation {
                    select("#txt_select_result").textIs("select=open:sel_row_05")
                    select("#txt_select_mode").textIs("mode=normal")
                }
            }
            scene(2, "行を長押しして選択モードへ") {
                action {
                    tap("#sel_row_03", holdSeconds: 1.0)
                }.expectation {
                    select("#txt_select_mode").textIs("mode=select")
                    select("#txt_select_count").textIs("selected=1")
                    select("#btn_edit").textIs("完了")
                }
            }
            scene(3, "選択モードでは押すと選択が増える(開かない)") {
                action {
                    tap("#sel_row_05")
                }.expectation {
                    select("#txt_select_count").textIs("selected=2")
                    select("#txt_select_result").textIs("select=open:sel_row_05")
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

    @Test("編集ボタンで入り、すべて選択 → キャンセル")
    func S0020() {
        scenario {
            scene(1, "編集で選択モードへ(何も選ばれていない)") {
                condition {
                    launchApp()
                    tap("#nav_select")
                }.action {
                    tap("#btn_edit")
                }.expectation {
                    select("#txt_select_mode").textIs("mode=select")
                    select("#txt_select_count").textIs("selected=0")
                }
            }
            scene(2, "すべて選択") {
                action {
                    tap("#btn_sel_all")
                }.expectation {
                    select("#txt_select_count").textIs("selected=20")
                }
            }
            scene(3, "キャンセルで通常モードへ") {
                action {
                    tap("#btn_sel_cancel")
                }.expectation {
                    select("#txt_select_mode").textIs("mode=normal")
                    select("#txt_select_count").textIs("selected=0")
                    select("#btn_edit").textIs("編集")
                }
            }
        }
    }
}
