// 61_折りたたみヘッダとタブ.swift
// 確かめる癖: CoordinatorLayout + AppBarLayout + TabLayout + ViewPager2。1回目の送りがヘッダの縮みに吸われる・
// 縦の容器(一覧)と横の容器(ページ)とヘッダの入れ子・タブの列はヘッダが縮んでも上端に貼り付く・タブごとに一覧の位置が違う。

import FTDSL

@TestClass
class 折りたたみヘッダとタブを扱えること {

    @Test("下へ送るとまずヘッダが縮み、縮み切ってから一覧が送られる")
    func S0010() {
        scenario {
            scene(1, "開く。ヘッダが出ている") {
                condition {
                    launchApp()
                    tap("#nav_tab_header", scroll: .down)
                }.expectation {
                    select("#txt_tabhdr_header").textIs("header=expanded")
                    select("#txt_tabhdr_tab").textIs("tab=posts")
                    exist("#txt_profile_header")
                }
            }
            scene(2, "下の投稿を探索で押す(最初の送りはヘッダの縮みに吸われる)") {
                action {
                    tap("#post_27", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=post_27")
                    select("#txt_tabhdr_header").textIs("header=collapsed")
                }
            }
            scene(3, "タブの列は縮んだヘッダの下に貼り付いている") {
                expectation {
                    exist("#tab_media")
                }
            }
            scene(4, "上端まで戻すとヘッダが戻る") {
                action {
                    scrollToTop()
                }.expectation {
                    select("#txt_tabhdr_header").textIs("header=expanded")
                    exist("#post_00")
                }
            }
        }
    }

    @Test("タブを替えると別の一覧になり、ヘッダのボタンも押せる")
    func S0020() {
        scenario {
            scene(1, "開いてフォロー") {
                condition {
                    launchApp()
                    tap("#nav_tab_header", scroll: .down)
                }.action {
                    tap("#btn_follow")
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=follow")
                }
            }
            scene(2, "メディアのタブ") {
                action {
                    tap("#tab_media")
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=media")
                    exist("#media_00")
                }
            }
            scene(3, "メディアの下の行") {
                action {
                    tap("#media_30", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=media_30")
                }
            }
            scene(4, "いいねのタブはまだ先頭") {
                action {
                    tap("#tab_likes")
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=likes")
                    exist("#like_00")
                }
            }
        }
    }

    @Test("ページを左右に払ってタブを替える")
    func S0030() {
        scenario {
            scene(1, "開く。左へ払う") {
                condition {
                    launchApp()
                    tap("#nav_tab_header", scroll: .down)
                }.action {
                    flickRightToLeft(scrollFrame: "#pager_profile")
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=media")
                }
            }
            scene(2, "右へ払って戻る") {
                action {
                    flickLeftToRight(scrollFrame: "#pager_profile")
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=posts")
                }
            }
        }
    }
}
