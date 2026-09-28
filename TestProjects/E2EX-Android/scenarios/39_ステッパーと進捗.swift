// 39_ステッパーと進捗.swift
// 確かめる癖: ステッパー・進捗バー(値が時間で変わる要素・回転インジケータの出入り)。

import FTDSL

@TestClass
class ステッパーと進捗を扱えること {

    @Test("数量を増減し、進捗の完了を待つ")
    func S0010() {
        scenario {
            scene(1, "増やして減らす") {
                condition {
                    launchApp()
                    tap("#nav_stepper", scroll: .down)
                }.action {
                    tap("#btn_qty_plus")
                    tap("#btn_qty_plus")
                    tap("#btn_qty_minus")
                }.expectation {
                    select("#txt_qty").textIs("qty=2")
                }
            }
            scene(2, "進捗を完了まで待つ") {
                action {
                    tap("#btn_start_progress")
                }.expectation {
                    select("#txt_progress", waitSeconds: 10).textIs("progress=done")
                    notExist("#spinner_busy")
                }
            }
        }
    }
}
