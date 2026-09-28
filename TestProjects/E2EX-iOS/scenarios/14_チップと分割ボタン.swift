// 14_チップと分割ボタン.swift
// 確かめる癖: FilterChip(選択状態の a11y)・SegmentedButton(単一選択の状態)・RangeSlider(つまみが2つ)。

import FTDSL

@TestClass
class チップと分割ボタンを操作できること {

    @Test("FilterChip の選択状態を切り替えて読む")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_chips", scroll: .down)
                }.expectation {
                    select("#txt_chip_result").textIs("wifi=false")
                    select("#chip_wifi").checkIsOFF()
                }
            }
            scene(2, "選ぶ") {
                action {
                    tap("#chip_wifi")
                }.expectation {
                    select("#txt_chip_result").textIs("wifi=true")
                    select("#chip_wifi").checkIsON()
                }
            }
            scene(3, "AssistChip") {
                action {
                    tap("#chip_assist")
                }.expectation {
                    select("#txt_assist_result").textIs("assist=tapped")
                }
            }
        }
    }

    @Test("SegmentedButton の単一選択を切り替えて読む")
    func S0020() {
        scenario {
            scene(1, "月を選ぶ") {
                condition {
                    launchApp()
                    tap("#nav_chips", scroll: .down)
                }.action {
                    tap("#seg_month")
                }.expectation {
                    select("#txt_seg_result").textIs("seg=month")
                    select("#seg_month").checkIsON()
                    select("#seg_day").checkIsOFF()
                }
            }
            scene(2, "ラベルで週を選ぶ") {
                action {
                    tap("週")
                }.expectation {
                    select("#txt_seg_result").textIs("seg=week")
                }
            }
        }
    }

    @Test("範囲の表示(iOS にレンジスライダーは無い)")
    func S0030() {
        scenario {
            scene(1, "初期値") {
                condition {
                    launchApp()
                    tap("#nav_chips", scroll: .down)
                }.expectation {
                    select("#txt_range_result").textIs("range=20-80")
                }
            }
        }
    }
}
