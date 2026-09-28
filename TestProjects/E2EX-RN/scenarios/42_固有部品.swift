// 42_固有部品.swift
// 確かめる癖(RN 固有): FlashList(仮想化された一覧)/ core の Modal / core の Switch。
// 契約は E2EXAppRN/docs/ui-contract.md §第2弾の実装(React Native)

import FTDSL

@TestClass
class RNの固有部品を操作できること {

    @Test("FlashList・Modal・Switch")
    func S0010() {
        scenario {
            scene(1, "FlashList の画面外の行") {
                condition {
                    launchApp()
                    tap("#nav_native", scroll: .down)
                }.action {
                    tap("#flash_row_30", scroll: .down)
                }.expectation {
                    select("#txt_native_result", scroll: .up).textIs("native=flash:30")
                }
            }
            scene(2, "Modal") {
                action {
                    tap("#btn_modal_open")
                    tap("#btn_modal_ok")
                }.expectation {
                    select("#txt_native_result").textIs("native=modal:ok")
                }
            }
            scene(3, "Switch") {
                action {
                    tap("#sw_core")
                }.expectation {
                    select("#txt_native_result").textStartsWith("native=switch:")
                }
            }
        }
    }
}
