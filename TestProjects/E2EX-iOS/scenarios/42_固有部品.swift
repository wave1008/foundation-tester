// 42_固有部品.swift
// 確かめる癖(iOS 固有): UICollectionView(compositional layout・UIKit の埋め込み)/ .popover(iPhone ではシート状)/
// 小さい detent のシート。契約は E2EXAppIOS/docs/ui-contract.md §第2弾の実装(iOS)

import FTDSL

@TestClass
class iOSの固有部品を操作できること {

    @Test("コレクションビュー・ポップオーバー・小さいシート")
    func S0010() {
        scenario {
            scene(1, "コレクションビューのセル") {
                condition {
                    launchApp()
                    tap("#nav_native", scroll: .down)
                }.action {
                    tap("#cv_item_2")
                }.expectation {
                    select("#txt_native_result").textIs("native=collection:2")
                }
            }
            scene(2, "ポップオーバー") {
                action {
                    tap("#btn_popover")
                    tap("#btn_popover_ok")
                }.expectation {
                    select("#txt_native_result").textIs("native=popover:ok")
                }
            }
            scene(3, "小さい detent のシート") {
                action {
                    tap("#btn_detent")
                    tap("#btn_detent_tapped")
                }.expectation {
                    select("#txt_native_result").textIs("native=detent:tapped")
                }
            }
        }
    }
}
