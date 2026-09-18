// 20_画像で探す.swift
// fleetest 機能: `findImage` / `findImages` / `findImageWithScrollDown`(Shirates Vision の移植)と、
// 見つけた要素の `FTElement.tap()`(見つけた枠の中心を座標で叩く)。
// テンプレートは DefaultClassifier の見本(vision/classifiers/DefaultClassifier/Controls/ と Home/)。
// **見本は Android だけ**(`@a`)。
// **この SUT に置く意味**: View/XML + 一部 Compose の混在で、Checkbox / RadioButton は `checkBox` に丸められる
// (docs/ui-contract.md)。id で掴むので型語彙は影響しないが、View の Switch は Compose の Switch と
// 描画が違う = 見本は SUT ごとに採る、の witness。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class 画像で要素を探す {

    @Test("id の無いスイッチを画像で掴んで叩く")
    func S0010() {
        scenario {
            scene(1, "ID なし画面のスイッチ2つを findImages で見つける") {
                condition {
                    launchApp()
                    tap("#nav_noid")
                }.action {
                    // ID なし画面のスイッチは View の SwitchCompat(122x71)で、コントロール画面の Compose Switch
                    // (137x126)とは形が違い、アスペクト比の許容幅にも入らない。見本は画面ごとに採る
                    for element in findImages("[View Switch]") {
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
            scene(2, "オフのラジオ2つを findImages で見つける") {
                expectation {
                    // 見本はオフのラジオ。Material のオンのラジオ(#radio_a)は中を塗るので別の絵になり見つからない
                    // (SwiftUI の E2E-iOS では線の太さの差だけで距離 0.11 に収まる = SUT の 20 と違う点)
                    let ids = findImages("[Radio]").map { $0.id ?? "-" }.sorted()
                    ids.joined(separator: ",").thisIs("radio_b,radio_c")
                }
            }
        }
    }

    @Test("スクロールしながら画像で探す")
    func S0030() {
        scenario {
            scene(1, "ホームの最下行を findImageWithScrollDown で見つける") {
                condition {
                    launchApp()
                    tap("#tab_home")
                }.action {
                    // 文字だけが違う同じ形の行は距離で見分けにくい(E2E-iOS の 20 と同じ理由で閾値を絞る)
                    findImageWithScrollDown("[Diagnostics Nav]", threshold: 0.03).tap()
                }.expectation {
                    select("#txt_screen_title").textIs("診断")
                }
            }
        }
    }
}
