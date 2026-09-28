// 42_固有部品.swift
// 確かめる癖(CMP 固有): M3 Carousel(横に並ぶ幅の違う項目)/ NavigationRail / BottomSheetScaffold(常に覗いているシート)。
// 契約は E2EXAppCMP/docs/ui-contract.md §第2弾の実装(CMP)

import FTDSL

@TestClass
class CMPの固有部品を操作できること {

    @Test("カルーセル・ナビゲーションレール・常に覗いているシート")
    func S0010() {
        scenario {
            scene(1, "カルーセルの項目") {
                condition {
                    launchApp()
                    tap("#nav_native", scroll: .down)
                }.action {
                    tap("#carousel_item_1")
                }.expectation {
                    select("#txt_native_result").textIs("native=carousel:1")
                }
            }
            scene(2, "ナビゲーションレール") {
                action {
                    tap("#rail_item_search")
                }.expectation {
                    select("#txt_native_result").textStartsWith("native=rail:")
                }
            }
            scene(3, "覗いているシートのボタン") {
                action {
                    tap("#bss_peek_button")
                }.expectation {
                    select("#txt_native_result").textIs("native=bss:tapped")
                }
            }
        }
    }
}
