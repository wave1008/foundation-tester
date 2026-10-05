// 55_選択モード.swift
// 確かめる癖: ActionMode(長押しで入り、画面上部のバーが置き換わる)・同じタップの意味がモードで変わる・
// ラベルが変わる同一 #id(編集 ⇄ 完了)・選択状態は CheckedTextView の checked として公開される。

import FTDSL

@TestClass
class 選択モードに入って行を選べること {

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

    @Test("長押しで選択モードに入り、選んで削除する")
    func S0020() {
        scenario {
            scene(1, "開く。3 行目を長押し") {
                condition {
                    launchApp()
                    tap("#nav_select", scroll: .down)
                }.action {
                    tap("#sel_row_03", holdSeconds: 1.0)
                }.expectation {
                    select("#txt_select_mode").textIs("mode=select")
                    select("#txt_select_count").textIs("selected=1")
                    select("#btn_edit").textIs("完了")
                }
            }
            scene(2, "選択モードでは押すと選択が切り替わる(開かない)") {
                action {
                    tap("#sel_row_05")
                }.expectation {
                    select("#txt_select_count").textIs("selected=2")
                    select("#txt_select_result").textIs("select=none")
                    select("#sel_row_05").checkIsON()
                }
            }
            scene(3, "削除") {
                action {
                    tap("#btn_sel_delete")
                }.expectation {
                    select("#txt_select_result").textIs("select=deleted:03,05")
                    select("#txt_select_mode").textIs("mode=normal")
                    select("#btn_edit").textIs("編集")
                }
            }
        }
    }

    @Test("編集ボタンで入り、すべて選択とキャンセル")
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
            scene(3, "アイコンだけのキャンセルで抜ける(選択は捨てる)") {
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
                    tap("#sel_row_02")
                }.expectation {
                    select("#txt_select_count").textIs("selected=1")
                }.action {
                    tap("#btn_edit")
                }.expectation {
                    select("#txt_select_mode").textIs("mode=normal")
                    select("#txt_select_count").textIs("selected=0")
                }
            }
        }
    }
}
