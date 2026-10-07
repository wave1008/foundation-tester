// 05_日付ピッカー.swift
// 確かめる癖: DatePickerDialog(日付セルは内部部品で testTag を付けられない = ラベルで指すしかない。
// ラベルはロケールで変わる)。

import FTDSL

@TestClass
class 日付ピッカーで日付を選べること {

    @Test("日付セルをラベルで選んで OK")
    func S0010() {
        scenario {
            scene(1, "ダイアログを開く") {
                condition {
                    launchApp()
                    tap("#nav_date")
                }.action {
                    tap("#btn_open_date")
                }.expectation {
                    exist("#btn_date_ok")
                }
            }
            scene(2, "20日を選んで OK") {
                action {
                    // 英語ロケールのセルは「Tuesday, January 20」。部分一致の「*January 20*」は見出しの「January 2026」に先に当たる
                    tap("*1月20日*||*January 20||20")
                    tap("#btn_date_ok")
                }.expectation {
                    select("#txt_date_result").textIs("date=2026-01-20")
                }
            }
        }
    }

    @Test("キャンセル")
    func S0020() {
        scenario {
            scene(1, "開いてキャンセル") {
                condition {
                    launchApp()
                    tap("#nav_date")
                }.action {
                    tap("#btn_open_date")
                    tap("#btn_date_cancel")
                }.expectation {
                    select("#txt_date_result").textIs("date=cancel")
                    notExist("#btn_date_ok")
                }
            }
        }
    }
}
