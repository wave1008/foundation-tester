// 32_時刻ピッカー.swift
// 確かめる癖: 時刻ピッカー(ダイアログ・時計の文字盤は描画だけで要素が細かい)。

import FTDSL

@TestClass
class 時刻ピッカーで時刻を確定できること {

    @Test("初期値のまま OK")
    func S0010() {
        scenario {
            scene(1, "開いて OK") {
                condition {
                    launchApp()
                    tap("#nav_time", scroll: .down)
                }.action {
                    tap("#btn_open_time")
                    tap("#btn_time_ok")
                }.expectation {
                    select("#txt_time_result").textIs("time=09:30")
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
                    tap("#nav_time", scroll: .down)
                }.action {
                    tap("#btn_open_time")
                    tap("#btn_time_cancel")
                }.expectation {
                    select("#txt_time_result").textIs("time=cancel")
                    notExist("#btn_time_ok")
                }
            }
        }
    }
}
