// 11_タブ.swift
// 確かめる癖: PrimaryTabRow・ScrollableTabRow(横にはみ出すタブ列)・NavigationBar(アイコン + ラベル)。

import FTDSL

@TestClass
class タブを切り替えられること {

    @Test("固定タブ・横にはみ出すタブ・ナビゲーションバー")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_tabs", scroll: .down)
                }.expectation {
                    select("#txt_tab_content").textIs("content=A")
                }
            }
            scene(2, "固定タブを #id とラベルで") {
                action {
                    tap("#tab_b")
                }.expectation {
                    select("#txt_tab_content").textIs("content=B")
                }.action {
                    tap("タブC")
                }.expectation {
                    select("#txt_tab_content").textIs("content=C")
                }
            }
            scene(3, "画面外のタブへ横のスクロール探索で届く(送る領域はタブ列)") {
                action {
                    withScrollRight(scrollFrame: "#stab_row") {
                        tap("#stab_11")
                    }
                }.expectation {
                    select("#txt_stab_content").textIs("scroll-tab=11")
                }
            }
            scene(4, "ナビゲーションバー") {
                action {
                    // TabView のタブ項目には #id が付かない(E2EXAppIOS/docs/ui-contract.md)
                    tap("設定")
                }.expectation {
                    select("#txt_navbar_result").textIs("navbar=settings")
                }.action {
                    tap("探す")
                }.expectation {
                    select("#txt_navbar_result").textIs("navbar=search")
                }
            }
        }
    }
}
