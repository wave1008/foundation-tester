// 56_文中リンク.swift
// 確かめる癖: 1 つのノードの中に複数のタップ対象(リンクが子ノードで出るかは版次第)・
// 行全体が押せる行の中の入れ子のリンク・文の中心はリンクでない場所に当たりうる。

// 文中のリンクは `tap(要素, linkText:)` で押す(子ノードに出る Flutter / RN は木で、出ない CMP / Android / iOS は OCR で位置を決める)。

import FTDSL

@TestClass
class 文中のリンクだけを押せること {

    @Test("文の中のリンクをラベルで押し分ける")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_links", scroll: .down)
                }.expectation {
                    select("#txt_links_result").textIs("link=none")
                }
            }
            scene(2, "利用規約とプライバシーポリシー") {
                action {
                    tap("#txt_terms", linkText: "利用規約")
                }.expectation {
                    select("#txt_links_result").textIs("link=terms")
                }.action {
                    tap("#txt_terms", linkText: "プライバシーポリシー")
                }.expectation {
                    select("#txt_links_result").textIs("link=privacy")
                }
            }
            scene(3, "メンションと URL(外部へ遷移しない)") {
                action {
                    tap("#txt_post", linkText: "@alice")
                }.expectation {
                    select("#txt_links_result").textIs("link=mention:alice")
                }.action {
                    tap("#txt_post", linkText: "https://example.com/a")
                }.expectation {
                    select("#txt_links_result").textIs("link=url")
                    select("#txt_screen_title").textIs("文中リンク")
                }
            }
        }
    }

    @Test("行全体が押せる行の中の入れ子のリンク")
    func S0020() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_links", scroll: .down)
                }.expectation {
                    select("#txt_links_result").textIs("link=none")
                }
            }
            scene(2, "文中のこちらだけ押す") {
                action {
                    tap("#row_with_link", linkText: "こちら")
                }.expectation {
                    select("#txt_links_result").textIs("link=inner")
                }
            }
            scene(3, "行の本体(中心 = リンクの外)を押す") {
                action {
                    tap("#row_with_link")
                }.expectation {
                    select("#txt_links_result").textIs("link=row")
                }
            }
        }
    }

    @Test("段落の中心を押してもリンクかどうかは座標次第(echo はリンクの値か none)")
    func S0030() {
        scenario {
            scene(1, "段落の中心を押す") {
                condition {
                    launchApp()
                    tap("#nav_links", scroll: .down)
                }.action {
                    tap("#txt_terms")
                }.expectation {
                    select("#txt_links_result").textMatches("^link=(none|terms|privacy)$")
                }
            }
        }
    }
}
