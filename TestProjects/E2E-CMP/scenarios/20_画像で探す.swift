// 20_画像で探す.swift
// fleetest 機能: `findImage` / `findImages` / `findImage(scroll:)` / `existImage`(Shirates Vision の移植)と、
// 見つけた要素の `FTElement.tap()`(見つけた枠の中心を座標で叩く)。
// テンプレートは DefaultClassifier の見本(vision/classifiers/DefaultClassifier/Controls/ と Home/)。
// **iOS と Android の見本は別**(`@i` / `@a` の付いたファイル名。実行中の OS 用を先に試す)——
// Material の部品は同じ設計でも OS で描画の倍率・色が違う。
// **この SUT に置く意味**: 自前描画(Skia)の Compose では、iOS の in-app ブリッジで a11y の木が絵より
// 先に進む(v117 で撮る前に絵の追いつきを待つ)。その退行はこの SUT でしか出ない。
// 型語彙の差(iOS/Android で Checkbox・Radio は `button` / `checkBox`)は id で掴むので影響しない。

import FTDSL

@TestClass
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
                    // in-app は初回訪問でタップが返ってから 0.3〜0.45 秒のあいだ切り替え前の絵を返した。
                    // **XCUITest エンジン(--ios-xcuitest)では赤になる既知の制約**: 同じ遅れがあり直していない
                    // (docs/framework-differences.md §3)。待つ existImage(S0040)は通る
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
