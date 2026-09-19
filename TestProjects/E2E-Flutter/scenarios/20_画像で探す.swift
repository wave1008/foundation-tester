// 20_画像で探す.swift
// fleetest 機能: `findImage` / `findImages` / `findImage(scroll:)` / `existImage`(Shirates Vision の移植)と、
// 見つけた要素の `FTElement.tap()`(見つけた枠の中心を座標で叩く)。
// テンプレートは DefaultClassifier の見本(vision/classifiers/DefaultClassifier/Controls/ と Home/)。
// **iOS と Android の見本は別**(`@i` / `@a` の付いたファイル名。実行中の OS 用を先に試す)。
// **この SUT に置く意味**: Flutter も自前描画で、iOS の in-app では画面遷移のアニメーションの途中の絵が
// 返る(v117 は「木が変わったのに絵が操作前のまま」の間だけ待ち、遷移の完了は待たない)。
// Flutter の Checkbox は iOS/Android とも型 `switch`(docs/ui-contract.md 表 B)だが、画像は四角なので
// `[Switch]` の見本(丸いつまみ)とは距離が離れ、ID なし画面の `[Checkbox]` は空になる。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class 画像で要素を探す {

    @Test("id の無いスイッチを画像で掴んで叩く")
    func S0010() {
        scenario {
            scene(1, "ID なし画面のスイッチ2つを findImages で見つける") {
                condition {
                    launchApp()
                    tap("#nav_noid")
                }.action {
                    for element in findImages("[Switch]") {
                        element.tap()
                    }
                }.expectation {
                    select("notify=*").textIs("notify=on")
                    select("location=*").textIs("location=on")
                }
            }
            scene(2, "似た形の要素が無ければ空要素を返す(失敗しない)") {
                expectation {
                    findImage("[Checkbox]").isEmpty.thisIsTrue()
                }
            }
        }
    }

    @Test("コントロール画面で画像から要素を掴む")
    func S0020() {
        scenario {
            scene(1, "起動直後の初回訪問でチェックボックスを findImage で掴んで叩く") {
                condition {
                    // **launchApp の直後にタブを切り替えてすぐ撮る**のが要点(v117 の witness): CMP iOS の
                    // in-app は初回訪問でタップが返ってから 0.3〜0.45 秒のあいだ切り替え前の絵を返した
                    launchApp()
                    tap("#tab_controls")
                }.action {
                    findImage("[Checkbox]").tap()
                }.expectation {
                    select("#txt_cb_agree").textIs("agree=true")
                    findImage("[Switch]").idIs("sw_notify")
                }
            }
            scene(2, "ラジオ3つを findImages で見つける") {
                expectation {
                    // findImages はラベルの見本を全部使う。Material のオンのラジオ(#radio_a)は中を塗るので
                    // オフの見本からは遠いが、オンの見本(b_on)で当たる = 見本を1枚しか使わないと落ちる witness
                    let ids = findImages("[Radio]").map { $0.id ?? "-" }.sorted()
                    ids.joined(separator: ",").thisIs("radio_a,radio_b,radio_c")
                }
            }
        }
    }

    @Test("スクロールしながら画像で探す")
    func S0030() {
        scenario {
            scene(1, "ホームの最下行を findImage(scroll: .down) で見つける") {
                condition {
                    launchApp()
                    tap("#tab_home")
                }.action {
                    // 文字だけが違う同じ形の行は距離で見分けにくい(E2E-iOS の 20 と同じ理由で閾値を絞る)
                    findImage("[Diagnostics Nav]", threshold: 0.03, scroll: .down).tap()
                }.expectation {
                    select("#txt_screen_title").textIs("診断")
                }
            }
        }
    }

    @Test("画像があることを検証する")
    func S0040() {
        scenario {
            scene(1, "コントロール画面の部品を existImage で検証する") {
                condition {
                    launchApp()
                    tap("#tab_controls")
                }.expectation {
                    existImage("[Checkbox]")
                    existImage("[Switch]").idIs("sw_notify")
                }
            }
            scene(2, "ホームの最下行を existImage(scroll: .down) で検証する") {
                condition {
                    tap("#tab_home")
                }.expectation {
                    // 閾値を絞る理由は S0030 と同じ(文字だけが違う同じ形の行)
                    existImage("[Diagnostics Nav]", threshold: 0.03, scroll: .down).idIs("nav_diagnostics")
                }
            }
        }
    }
}
