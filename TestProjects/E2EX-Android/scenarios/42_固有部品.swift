// 42_固有部品.swift
// 確かめる癖(Android View 固有): Spinner(ドロップダウンは別ウィンドウ)/ MotionLayout の遷移。
// 契約は E2EXAppAndroid/docs/ui-contract.md §第2弾の実装(Android)

import FTDSL

@TestClass
class Androidの固有部品を操作できること {

    @Test("Spinner・MotionLayout")
    func S0010() {
        scenario {
            scene(1, "Spinner で B を選ぶ") {
                condition {
                    launchApp()
                    tap("#nav_native", scroll: .down)
                }.action {
                    tap("#spinner_native")
                    tap("B")
                }.expectation {
                    select("#txt_native_result").textIs("native=spinner:B")
                }
            }
            scene(2, "MotionLayout の遷移") {
                action {
                    tap("#btn_motion")
                }.expectation {
                    select("#txt_native_result", waitSeconds: 5).textIs("native=motion:end")
                }
            }
        }
    }
}
