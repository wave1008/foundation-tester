// 20_画像で探す.swift
// fleetest 機能: `findImage` / `findImages` / `findImageWithScrollDown`(Shirates Vision の移植)と、
// 見つけた要素の `FTElement.tap()`(見つけた枠の中心を座標で叩く)。
// テンプレートは DefaultClassifier の見本(vision/classifiers/DefaultClassifier/@i/…)。
// `[Switch]` / `[Checkbox]` / `[Radio]` はコントロール画面から、`[Keyboard Cover Nav]` はホームの最下行
// (#nav_keyboard_cover)から a11y の枠で切ったもの(`fleetest vision capture`)。
// **この SUT に置く意味**: SwiftUI はオンのラジオも見本(オフ)と距離 0.11 に収まり3つとも見つかる
// (Material の他 SUT は中を塗るので2つ)。XCUITest の木では飾りの Image が同じ枠に載る(候補の畳み方の witness)。
// ID なし画面のスイッチは id もラベルも無いので、セレクタではなく画像で掴むという本来の用途そのものになる。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class 画像で要素を探す {

    @Test("id の無いスイッチを画像で掴んで叩く")
    func S0010() {
        scenario {
            scene(1, "ID なし画面のスイッチ2つを findImages で見つける") {
                condition {
                    launchApp()
                    tap("#nav_noid")
                }.action {
                    // 見本はコントロール画面の #sw_notify(オフ)。同じ見た目のスイッチが2つある
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
            scene(1, "チェックボックスを findImage で掴んで叩く") {
                condition {
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
                    let ids = findImages("[Radio]").map { $0.id ?? "-" }.sorted()
                    ids.joined(separator: ",").thisIs("radio_a,radio_b,radio_c")
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
                    // **文字だけが違う同じ形の行は特徴量の距離で見分けにくい**(2026-09-19 実測: 見本の行 0.000・
                    // 他の行 0.084〜1.262 で、既定の閾値 0.15 だと最初の画面の #nav_gesture 等で止まる)。
                    // 閾値を絞るとスクロールしてから掴む。分類器のラベル一致だけで採る退行があると、
                    // 最初の画面の別の行で止まってここが赤になる(classificationConfirmed の witness)
                    findImageWithScrollDown("[Keyboard Cover Nav]", threshold: 0.03).tap()
                }.expectation {
                    select("#txt_screen_title").textIs("キーボードの覆い")
                }
            }
        }
    }
}
