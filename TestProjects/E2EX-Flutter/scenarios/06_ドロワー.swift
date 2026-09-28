// 06_ドロワー.swift
// 確かめる癖: ModalNavigationDrawer(閉じていても木に残るか・スクリム・横の払いで開く)。

import FTDSL

@TestClass
class ドロワーを操作できること {

    @Test("ボタンで開いて項目を選ぶ")
    func S0010() {
        scenario {
            scene(1, "閉じている間は項目が見えない") {
                condition {
                    launchApp()
                    tap("#nav_drawer")
                }.expectation {
                    select("#txt_drawer_state").textIs("drawerOpen=false")
                    notExist("#drawer_item_sent")
                }
            }
            // 開いている間、iOS は背後の画面を木から外す(スクリムの「閉じる」ボタンだけが残る)ので、
            // 背後の #txt_drawer_state は閉じてから読む
            scene(2, "開く") {
                action {
                    tap("#btn_open_drawer")
                }.expectation {
                    exist("#txt_drawer_header")
                }
            }
            scene(3, "送信済みを選ぶと閉じる") {
                action {
                    tap("#drawer_item_sent")
                }.expectation {
                    select("#txt_drawer_result").textIs("drawer=sent")
                    select("#txt_drawer_state").textIs("drawerOpen=false")
                }
            }
        }
    }
}
