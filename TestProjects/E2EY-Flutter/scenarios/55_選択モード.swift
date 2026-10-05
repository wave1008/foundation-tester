// 55_選択モード.swift
// 確かめる癖: 同じタップの意味がモードで変わる(通常 = 開く / 選択中 = 切り替え)・長押しで入る・
// 同一 #id のラベルが変わる(編集 → 完了)・選択状態は標準の checked として読む。

import FTDSL

@TestClass
class 選択モードを操作できること {

    @Test("長押しで入り、行を足して削除する")
    func S0010() {
        scenario {
            scene(1, "通常モードで行を押すと開く") {
                condition {
                    launchApp()
                    tap("#nav_select", scroll: .down)
                }.expectation {
                    select("#txt_select_mode").textIs("mode=normal")
                }.action {
                    tap("#sel_row_03")
                }.expectation {
                    select("#txt_select_result").textIs("select=open:sel_row_03")
                }
            }
            scene(2, "行を長押しすると選択モードに入りその行が選ばれる") {
                action {
                    tap("#sel_row_05", holdSeconds: 1.0)
                }.expectation {
                    select("#txt_select_mode").textIs("mode=select")
                    select("#txt_select_count").textIs("selected=1")
                    select("#sel_row_05").checkIsON()
                }
            }
            scene(3, "選択モードでは押すと切り替わる(開かない)") {
                action {
                    tap("#sel_row_07")
                }.expectation {
                    select("#txt_select_count").textIs("selected=2")
                    select("#sel_row_07").checkIsON()
                    select("#txt_select_result").textIs("select=open:sel_row_03")
                }
            }
            scene(4, "削除すると通常モードへ戻る") {
                action {
                    tap("#btn_sel_delete")
                }.expectation {
                    select("#txt_select_result").textIs("select=deleted:05,07")
                    select("#txt_select_mode").textIs("mode=normal")
                    notExist("#sel_row_05")
                }
            }
        }
    }

    @Test("編集ボタンでも入り、すべて選択とキャンセル")
    func S0020() {
        scenario {
            scene(1, "編集で入ると何も選ばれていない・ラベルは完了") {
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
            scene(3, "キャンセルで選択を捨てて通常モードへ") {
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
