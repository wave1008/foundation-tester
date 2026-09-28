// 04_メニュー.swift
// 確かめる癖: DropdownMenu / ExposedDropdownMenuBox(Popup = Android では別ウィンドウ・外側のタップは
// 背後へ通らずメニューを閉じるだけ・読み取り専用の TextField の値の読み出し)。

import FTDSL

@TestClass
class メニューを操作できること {

    @Test("DropdownMenu を #id とラベルで選ぶ・外側のタップで閉じる")
    func S0010() {
        scenario {
            scene(1, "メニューを開いて #id で選ぶ") {
                condition {
                    launchApp()
                    tap("#nav_menu")
                }.action {
                    tap("#btn_open_menu")
                    tap("#menu_item_share")
                }.expectation {
                    select("#txt_menu_result").textIs("menu=share")
                    notExist("#menu_item_copy")
                }
            }
            scene(2, "ラベルで選ぶ") {
                action {
                    tap("#btn_open_menu")
                    tap("削除")
                }.expectation {
                    select("#txt_menu_result").textIs("menu=delete")
                }
            }
            // SwiftUI の Menu は「閉じた」を通知しないので echo は変わらない。外側(右上の空き)を押して
            // 項目が消えたことだけを見る(画面の下の方はメニューが伸びて項目に当たる)
            scene(3, "メニューの外側を押すと閉じるだけ") {
                action {
                    tap("#btn_open_menu")
                    exist("#menu_item_copy")
                    tap(x: 370, y: 140)
                }.expectation {
                    select("#txt_menu_result").textIs("menu=delete")
                    notExist("#menu_item_copy")
                }
            }
        }
    }

    @Test("ExposedDropdownMenuBox で選び、欄の値を読む")
    func S0020() {
        scenario {
            scene(1, "候補を開いて選ぶ") {
                condition {
                    launchApp()
                    tap("#nav_menu")
                }.action {
                    tap("#field_fruit")
                    // Picker(.menu) の項目には #id が付かない(E2EXAppIOS/docs/ui-contract.md)
                    tap("バナナ")
                }.expectation {
                    select("#txt_fruit_result").textIs("fruit=banana")
                    // SwiftUI の Picker(.menu) は選んだ値をラベル側に出す(「果物, バナナ」。value は nil)
                    select("#field_fruit").textContains("バナナ")
                }
            }
        }
    }
}
