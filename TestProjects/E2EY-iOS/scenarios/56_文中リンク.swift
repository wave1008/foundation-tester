// 56_文中リンク.swift
// 確かめる癖: 1つの Text の中に複数のタップ対象(リンクは子ノードとして木に出ない)・文の中心を押すとリンクでない場所に当たる・
// 行全体が押せる行の中の入れ子のタップ対象。リンク部分は文字列の位置で指す(tap の x/y は枠に対する比率)。

import FTDSL

@TestClass
class 文中のリンクを押せること {

    @Test("利用規約とプライバシーポリシー(1つの文の中の2つのリンク)")
    func S0010() {
        scenario {
            scene(1, "文の中心はリンクではない") {
                condition {
                    launchApp()
                    tap("#nav_links")
                }.action {
                    tap("#txt_terms")
                }.expectation {
                    select("#txt_links_result").textIs("link=none")
                }
            }
            scene(2, "利用規約をラベルで押す") {
                action {
                    tap("利用規約")
                }.expectation {
                    select("#txt_links_result").textIs("link=terms")
                }
            }
            scene(3, "プライバシーポリシーをラベルで押す") {
                action {
                    tap("プライバシーポリシー")
                }.expectation {
                    select("#txt_links_result").textIs("link=privacy")
                }
            }
        }
    }

    @Test("メンションと URL")
    func S0020() {
        scenario {
            scene(1, "@alice") {
                condition {
                    launchApp()
                    tap("#nav_links")
                }.action {
                    tap("@alice")
                }.expectation {
                    select("#txt_links_result").textIs("link=mention:alice")
                }
            }
            scene(2, "URL(外へ遷移しない)") {
                action {
                    tap("https://example.com/a")
                }.expectation {
                    select("#txt_links_result").textIs("link=url")
                    select("#txt_screen_title").textIs("文中リンク")
                }
            }
        }
    }

    @Test("行の本体と文中の「こちら」は別のタップ対象")
    func S0030() {
        scenario {
            scene(1, "行の本体") {
                condition {
                    launchApp()
                    tap("#nav_links")
                }.action {
                    tap("#row_with_link")
                }.expectation {
                    select("#txt_links_result").textIs("link=row")
                }
            }
            scene(2, "文中のこちら") {
                action {
                    tap("こちら")
                }.expectation {
                    select("#txt_links_result").textIs("link=inner")
                }
            }
        }
    }
}
