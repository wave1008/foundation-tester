// 61_折りたたみヘッダとタブ.swift
// 確かめる癖: 1回目の送りがヘッダの縮みに吸われる・縦の容器(一覧)と横の容器(ページ)とヘッダの入れ子・タブの列は上端に貼り付く。

import FTDSL

@TestClass
class 折りたたみヘッダの下のタブの一覧を扱えること {

    @Test("ヘッダのボタンと、縮んだヘッダの下の行")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_tab_header", scroll: .down)
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=none")
                    select("#txt_tabhdr_tab").textIs("tab=posts")
                    select("#txt_tabhdr_header").textIs("header=expanded")
                }
            }
            scene(2, "ヘッダのボタン") {
                action {
                    tap("#btn_follow")
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=follow")
                }
            }
            scene(3, "下の行へ送るとヘッダが縮む") {
                action {
                    tap("#post_27", scroll: .down, maxSwipes: 20)
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=post_27")
                    select("#txt_tabhdr_header").textIs("header=collapsed")
                }
            }
            scene(4, "上端まで戻すとヘッダが戻る(iOS。Android は S0090 = 既知の制約)") {
                action {
                    ios { scrollToTop() }
                }.expectation {
                    ios {
                        select("#txt_tabhdr_header").textIs("header=expanded", waitSeconds: 5)
                        exist("#post_00")
                    }
                }
            }
        }
    }

    @Draft("既知の制約: Android の scrollToTop は a11y のスクロール操作で上端へ送るので、自前の nestedScroll で縮めたヘッダ(Compose)・collapsible-tab-view(RN)を開けない(最後の1本を指のドラッグに戻すと、ヘッダの無い画面で引っ張って更新に化ける)")
    @Test("Android: 縮んだヘッダを scrollToTop で開く")
    func S0090() {
        scenario {
            scene(1, "縮める") {
                condition {
                    launchApp()
                    tap("#nav_tab_header", scroll: .down)
                }.action {
                    tap("#post_27", scroll: .down, maxSwipes: 20)
                }.expectation {
                    select("#txt_tabhdr_header").textIs("header=collapsed")
                }
            }
            scene(2, "上端まで戻すとヘッダが戻る") {
                action {
                    scrollToTop()
                }.expectation {
                    select("#txt_tabhdr_header").textIs("header=expanded", waitSeconds: 5)
                }
            }
        }
    }

    @Test("タブを替える・横に払って替える")
    func S0020() {
        scenario {
            scene(1, "メディアのタブ") {
                condition {
                    launchApp()
                    tap("#nav_tab_header", scroll: .down)
                }.action {
                    tap("#tab_media")
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=media", waitSeconds: 5)
                }.action {
                    tap("#media_03")
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=media_03")
                }
            }
            scene(2, "縮めたあとでも貼り付いたタブを押せる") {
                action {
                    tap("#media_25", scroll: .down, maxSwipes: 20)
                    tap("#tab_likes")
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=likes", waitSeconds: 5)
                    select("#txt_tabhdr_header").textIs("header=collapsed")
                }
            }
            scene(3, "ページを右へ払って1つ戻る") {
                action {
                    flickLeftToRight()
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=media", waitSeconds: 5)
                }
            }
        }
    }
}
