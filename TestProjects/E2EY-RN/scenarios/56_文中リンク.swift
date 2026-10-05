// 56_文中リンク.swift
// 確かめる癖: 1つのノードの中に複数のタップ対象(入れ子の Text の onPress)。リンクは子ノードとして出るか
// フレームワークと版次第で、文の中心はリンクでない場所に当たる。行全体が押せる行の中の入れ子のリンク。
// 契約の罠: iOS は accessible な祖先が子を1要素へ畳む(E2EYAppRN/docs/ui-contract.md)。

import FTDSL

@TestClass
class 文中のリンクを個別に押せること {

    @Test("段落の中の2つのリンクをラベルで押し分ける")
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

    @Test("メンションと URL")
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
            scene(2, "@alice") {
                action {
                    tap("@alice")
                }.expectation {
                    select("#txt_links_result").textIs("link=mention:alice")
                }
            }
            scene(3, "URL(外へ遷移しない)") {
                action {
                    tap("https://example.com/a")
                }.expectation {
                    select("#txt_links_result").textIs("link=url")
                    exist("#txt_links_result")
                }
            }
        }
    }

    @Test("リンクでない場所(段落の中心)を押しても何も起きない")
    func S0030() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_links", scroll: .down)
                }.expectation {
                    select("#txt_links_result").textIs("link=none")
                }
            }
            scene(2, "段落の中心") {
                action {
                    tap("#txt_terms")
                    wait(1)
                }.expectation {
                    select("#txt_links_result").textIs("link=none")
                }
            }
        }
    }

    @Test("行の中の入れ子のリンクと行の本体")
    func S0040() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_links", scroll: .down)
                }.expectation {
                    select("#txt_links_result").textIs("link=none")
                }
            }
            scene(2, "文中の こちら だけ") {
                action {
                    tap("こちら")
                }.expectation {
                    select("#txt_links_result").textIs("link=inner")
                }
            }
            scene(3, "行の本体") {
                action {
                    tap("#row_with_link")
                }.expectation {
                    select("#txt_links_result").textMatches("^link=(row|inner)$")
                }
            }
        }
    }
}
