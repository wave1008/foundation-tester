// 56_文中リンク.swift
// 確かめる癖: 1つの Text(AnnotatedString)の中の複数のタップ対象。リンクが子ノードとして出るかは版次第なので文字列で指す。
// 文の中心はリンクでない場所に当たる・行全体が押せる行の中の入れ子のタップ対象。

import FTDSL

@TestClass
class 文中のリンクだけを押せること {

    @Test("段落の中の利用規約とプライバシーポリシー")
    func S0010() {
        scenario {
            scene(1, "開く。リンクでない場所(段落の中心)を押しても何も起きない") {
                condition {
                    launchApp()
                    tap("#nav_links", scroll: .down)
                }.action {
                    tap("#txt_terms")
                }.expectation {
                    select("#txt_links_result").textIs("link=none")
                }
            }
            scene(2, "利用規約") {
                action {
                    tap("利用規約")
                }.expectation {
                    select("#txt_links_result").textIs("link=terms")
                }
            }
            scene(3, "プライバシーポリシー") {
                action {
                    tap("プライバシーポリシー")
                }.expectation {
                    select("#txt_links_result").textIs("link=privacy")
                }
            }
        }
    }

    @Test("メンションと URL(外部へ遷移しない)")
    func S0020() {
        scenario {
            scene(1, "@alice") {
                condition {
                    launchApp()
                    tap("#nav_links", scroll: .down)
                }.action {
                    tap("@alice")
                }.expectation {
                    select("#txt_links_result").textIs("link=mention:alice")
                }
            }
            scene(2, "URL") {
                action {
                    tap("https://example.com/a")
                }.expectation {
                    select("#txt_links_result").textIs("link=url")
                    select("#txt_screen_title").textIs("文中リンク")
                }
            }
        }
    }

    @Test("行全体が押せる行の中の入れ子のタップ対象")
    func S0030() {
        scenario {
            scene(1, "行の本体") {
                condition {
                    launchApp()
                    tap("#nav_links", scroll: .down)
                }.action {
                    tap("#row_with_link")
                }.expectation {
                    select("#txt_links_result").textIs("link=row")
                }
            }
            scene(2, "文中のこちらだけ") {
                action {
                    tap("こちら")
                }.expectation {
                    select("#txt_links_result").textIs("link=inner")
                }
            }
        }
    }
}
