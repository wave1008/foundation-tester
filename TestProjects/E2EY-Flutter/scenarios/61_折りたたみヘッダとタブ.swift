// 61_折りたたみヘッダとタブ.swift
// 確かめる癖: 1 回目の送りがヘッダの縮みに吸われる・縦の容器(一覧)と横の容器(ページ)とヘッダの入れ子・
// タブの列はヘッダが縮んでも上端に貼り付く・タブごとに一覧の位置が違う。

import FTDSL

@TestClass
class 折りたたみヘッダとタブを操作できること {

    @Test("送るとまずヘッダが縮み、上端へ戻すとヘッダが戻る")
    func S0010() {
        scenario {
            scene(1, "開くと伸びたヘッダ") {
                condition {
                    launchApp()
                    tap("#nav_tab_header", scroll: .down)
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=posts")
                    select("#txt_tabhdr_header").textIs("header=expanded")
                }.action {
                    tap("#btn_follow")
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=follow")
                }
            }
            scene(2, "深い投稿を探索で押す") {
                action {
                    tap("#post_20", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=post_20")
                    select("#txt_tabhdr_header").textIs("header=collapsed", waitSeconds: 5)
                }
            }
            scene(3, "ヘッダが縮んでもタブの列は上端に貼り付いて押せる") {
                action {
                    tap("#tab_media")
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=media", waitSeconds: 5)
                }
            }
            scene(4, "上端へ戻すとヘッダが戻る") {
                action {
                    scrollToTop()
                }.expectation {
                    select("#txt_tabhdr_header").textIs("header=expanded", waitSeconds: 5)
                }
            }
        }
    }

    @Test("タブを押して切り替え、左右に払っても切り替わる")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_tab_header", scroll: .down)
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=posts")
                }
            }
            scene(2, "メディアのタブを押して一覧の行を押す") {
                action {
                    tap("#tab_media")
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=media", waitSeconds: 5)
                }.action {
                    tap("#media_10", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=media_10")
                }
            }
            scene(3, "左へ払うと次のタブ") {
                action {
                    flickRightToLeft()
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=likes", waitSeconds: 5)
                }.action {
                    tap("#like_05", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=like_05")
                }
            }
        }
    }
}
