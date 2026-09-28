// 02_ページャ.swift
// 確かめる癖: HorizontalPager(1ページ = 画面幅のスナップ・隣のページは木に居るが画面外)。
// フリックで1ページ送る・ボタンでのプログラム送り・横方向のスクロール探索・左端への送り。

import FTDSL

@TestClass
class ページャを操作できること {

    @Test("フリック・プログラム送り・横のスクロール探索")
    func S0010() {
        scenario {
            scene(1, "ページャを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_pager")
                }.expectation {
                    select("#txt_pager_state").textIs("page=0")
                }
            }
            scene(2, "右から左へフリックすると次のページ") {
                action {
                    flickRightToLeft(scrollFrame: "#pager_main")
                }.expectation {
                    select("#txt_pager_state").textIs("page=1")
                }
            }
            scene(3, "見えているページのボタンを押せる") {
                action {
                    tap("#btn_page_1")
                }.expectation {
                    select("#txt_pager_result").textIs("pager=tapped 1")
                }
            }
            scene(4, "ボタンでプログラム送り") {
                action {
                    tap("#btn_pager_next")
                }.expectation {
                    select("#txt_pager_state").textIs("page=2")
                    exist("#txt_page_2")
                }
            }
            scene(5, "画面外のページのボタンへ横のスクロール探索で届く(送る領域はページャ)") {
                action {
                    withScrollRight(scrollFrame: "#pager_main") {
                        tap("#btn_page_4")
                    }
                }.expectation {
                    select("#txt_pager_result").textIs("pager=tapped 4")
                    select("#txt_pager_state").textIs("page=4")
                }
            }
            scene(6, "左端まで送ると最初のページ") {
                action {
                    scrollToLeftEdge(scrollFrame: "#pager_main")
                }.expectation {
                    select("#txt_pager_state").textIs("page=0")
                }
            }
        }
    }
}
