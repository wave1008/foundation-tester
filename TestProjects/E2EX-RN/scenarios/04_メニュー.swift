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
            // 開いている間は背後の画面が木から外れる(両 OS)ので、外側は要素で指せない。
            // Android は戻る、iOS は画面の空いた場所(メニューの下)を座標で押す
            scene(3, "メニューの外側を押すと閉じるだけ") {
                action {
                    tap("#btn_open_menu")
                    exist("#menu_item_copy")
                    android {
                        back()
                    }
                    ios {
                        tap(x: 200, y: 600)
                    }
                }.expectation {
                    select("#txt_menu_result").textIs("menu=dismissed")
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
                    tap("#opt_fruit_banana")
                }.expectation {
                    select("#txt_fruit_result").textIs("fruit=banana")
                    // 値の出し方は OS で違う(E2EXAppRN/docs/ui-contract.md)。選んだことは echo で確かめる
                }
            }
        }
    }
}
