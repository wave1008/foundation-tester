// 03_ボトムシート.swift
// 確かめる癖: ModalBottomSheet(Android では別ウィンドウ・既定は半分まで展開・中のリストを送ると
// シートが先に伸びる・スクリムが背後を覆う)。

import FTDSL

@TestClass
class ボトムシートを操作できること {

    @Test("選択肢を選ぶと閉じて結果が出る")
    func S0010() {
        scenario {
            scene(1, "シートを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_sheet")
                    tap("#btn_open_sheet")
                }.expectation {
                    exist("#txt_sheet_title")
                }
            }
            scene(2, "選択肢 2") {
                action {
                    tap("#btn_sheet_opt_2")
                }.expectation {
                    select("#txt_sheet_result").textIs("sheet=opt2")
                    notExist("#txt_sheet_title")
                }
            }
        }
    }

    @Test("シートの中のリストをスクロール探索して押す")
    func S0020() {
        scenario {
            scene(1, "シートを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_sheet")
                    tap("#btn_open_sheet")
                }.expectation {
                    exist("#txt_sheet_title")
                }
            }
            scene(2, "折り返しの下の行へ届く") {
                action {
                    tap("#row_sheet_25", scroll: .down)
                }.expectation {
                    select("#txt_sheet_result").textIs("sheet=row25")
                }
            }
        }
    }

    @Test("見出しを下の行まで払って閉じる")
    func S0030() {
        scenario {
            scene(1, "シートを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_sheet")
                    tap("#btn_open_sheet")
                }.expectation {
                    exist("#txt_sheet_title")
                }
            }
            // swipeBy は対象の大きさに対する比率(片側 0.9 まで)なので、小さい見出しでは数 pt しか動かない。
            // 対象より遠くへ払うのは swipeElementToElement
            scene(2, "見出しをシートの下の行まで払う") {
                action {
                    swipeElementToElement("#txt_sheet_title", "#row_sheet_04", durationSeconds: 0.3)
                }.expectation {
                    select("#txt_sheet_result").textIs("sheet=dismissed")
                    notExist("#txt_sheet_title")
                }
            }
        }
    }
}
