// 24_ブリッジの値供給.swift
// E2E-CMP の同名シナリオの View/XML 版(狙いと背景はあちらの冒頭コメント参照)。
// SeekBar も供給源は同じ `getRangeInfo()` だが、**Compose とは別の View 実装**なので
// フレームワーク差の退行はここでしか出ない。表記は実測どおり "50"(2026-08-08・Emulator)。

import FTDSL

@TestClass(app: "com.ftester.e2e.android")
class ブリッジが要素の状態を供給していること {

    @Test("Slider の現在値が value として木に載る(SeekBar の RangeInfo)")
    func S0010() {
        scenario {
            scene(1, "コントロールタブを初期状態で開く") {
                condition {
                    launchApp()
                    tap("#tab_controls")
                    tap("#btn_controls_reset")
                }.expectation {
                    select("#txt_slider").textIs("volume=50")
                }
            }
            scene(2, "ブリッジの供給を echo とは独立に確認する") {
                expectation {
                    select("#slider_volume").valueIs("50")
                }
            }
        }
    }
}
