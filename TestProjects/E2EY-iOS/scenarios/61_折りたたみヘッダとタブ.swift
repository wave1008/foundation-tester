// 61_折りたたみヘッダとタブ.swift
// 確かめる癖: 1回目の送りがヘッダの縮みに吸われる(ヘッダが縮み切ってから一覧が送られる)・
// 縦の容器(一覧)と横の容器(ページ)とヘッダの入れ子・タブの列は縮んだヘッダの下で上端に貼り付く。

import FTDSL

@TestClass
class 折りたたみヘッダとタブを操作できること {

    @Test("下へ送るとヘッダが縮み、上端まで戻すと戻る")
    func S0010() {
        scenario {
            scene(1, "開く(ヘッダが出ている)") {
                condition {
                    launchApp()
                    tap("#nav_tab_header")
                }.action {
                    tap("#btn_follow")
                }.expectation {
                    select("#txt_tabhdr_header").textIs("header=expanded")
                    select("#txt_tabhdr_result").textIs("tabhdr=follow")
                }
            }
            scene(2, "投稿 27 まで送って押す(ヘッダは縮む)") {
                action {
                    tap("#post_27", scroll: .down)
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=post_27")
                    select("#txt_tabhdr_header").textIs("header=collapsed")
                    exist("#tab_media")
                }
            }
            scene(3, "上端まで戻すとヘッダが戻る") {
                action {
                    scrollToTop()
                }.expectation {
                    select("#txt_tabhdr_header", waitSeconds: 3).textIs("header=expanded")
                }
            }
        }
    }

    @Test("タブを替えて、ページを横に払って切り替える")
    func S0020() {
        scenario {
            scene(1, "メディアのタブを押す") {
                condition {
                    launchApp()
                    tap("#nav_tab_header")
                }.action {
                    tap("#tab_media")
                }.expectation {
                    select("#txt_tabhdr_tab", waitSeconds: 3).textIs("tab=media")
                }.action {
                    tap("#media_05", waitSeconds: 3)
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=media_05")
                }
            }
            scene(2, "ページを右から左へ払ってメディアからいいねへ") {
                action {
                    flickRightToLeft(scrollFrame: "#media_05")
                }.expectation {
                    select("#txt_tabhdr_tab", waitSeconds: 3).textIs("tab=likes")
                }
            }
        }
    }
}
