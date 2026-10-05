// 61_折りたたみヘッダとタブ.swift
// 確かめる癖: 縦の一覧を下へ送ると、まずヘッダが縮み、縮み切ってから一覧が送られる(1回目の送りが
// ヘッダの縮みに吸われる)。縦(一覧)・横(ページ)・ヘッダの入れ子。タブを替えると一覧の位置がタブごとに違う。
// react-native-collapsible-tab-view。

import FTDSL

@TestClass
class 折りたたみヘッダとタブを操作できること {

    @Test("ヘッダが出ている間にフォローを押せる")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_tab_header", scroll: .down)
                }.expectation {
                    select("#txt_tabhdr_header").textIs("header=expanded")
                    select("#txt_tabhdr_tab").textIs("tab=posts")
                }
            }
            scene(2, "フォロー") {
                action {
                    tap("#btn_follow")
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=follow")
                }
            }
        }
    }

    @Test("下へ送るとヘッダが縮み、奥の投稿へ届く")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_tab_header", scroll: .down)
                }.expectation {
                    select("#txt_tabhdr_header").textIs("header=expanded")
                }
            }
            scene(2, "奥の投稿を探索で押す") {
                action {
                    tap("#post_27", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=post_27")
                    select("#txt_tabhdr_header").textIs("header=collapsed", waitSeconds: 3)
                }
            }
            scene(3, "上端まで戻すとヘッダが戻る(iOS。Android は S0090 = 既知の制約)") {
                action {
                    ios { scrollToTop() }
                }.expectation {
                    ios {
                        select("#txt_tabhdr_header").textIs("header=expanded", waitSeconds: 3)
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
                    tap("#post_27", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_tabhdr_header").textIs("header=collapsed", waitSeconds: 3)
                }
            }
            scene(2, "上端まで戻すとヘッダが戻る") {
                action {
                    scrollToTop()
                }.expectation {
                    select("#txt_tabhdr_header").textIs("header=expanded", waitSeconds: 3)
                }
            }
        }
    }

    @Draft("既知の制約: iOS でタブを替えた直後、ヘッダに覆われた行が木では覆われていない位置に居る(覆っている物が木に出ないので名指しできない)")
    @Test("タブを押して切り替え、別のタブの一覧の行を押す")
    func S0030() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_tab_header", scroll: .down)
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=posts")
                }
            }
            scene(2, "メディアへ") {
                action {
                    tap("#tab_media")
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=media", waitSeconds: 3)
                }.action {
                    tap("#media_03")
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=media_03")
                }
            }
            scene(3, "いいねへ") {
                action {
                    tap("#tab_likes")
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=likes", waitSeconds: 3)
                }.action {
                    tap("#like_02")
                }.expectation {
                    select("#txt_tabhdr_result").textIs("tabhdr=like_02")
                }
            }
        }
    }

    @Test("ページを左右に払ってタブを切り替える")
    func S0040() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_tab_header", scroll: .down)
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=posts")
                }
            }
            scene(2, "右から左へ払う") {
                action {
                    flickRightToLeft(scrollFrame: "#post_02")
                }.expectation {
                    select("#txt_tabhdr_tab").textIs("tab=media", waitSeconds: 3)
                }
            }
        }
    }
}
