// 01_ナビゲーション.swift
// 確かめる癖: navigation-compose の NavHost(引数付きルート・積み重ね)・TopAppBar のアイコンだけの戻る
// (contentDescription だけがラベル)・システムの戻る(Android の back / iOS のエッジスワイプ)。
// 契約は E2EXAppCMP/docs/ui-contract.md。

import FTDSL

@TestClass
class ナビゲーションが正しく働くこと {

    @Test("引数付きルートの積み重ねとアイコンだけの戻る")
    func S0010() {
        scenario {
            scene(1, "ホームが出る") {
                condition {
                    launchApp()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EX ホーム")
                }
            }
            scene(2, "折り返しの下の行から引数付き遷移の画面へ") {
                action {
                    tap("#nav_detail", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("引数付き遷移")
                }
            }
            scene(3, "引数付きルートを積む") {
                action {
                    tap("#detail_link_2")
                }.expectation {
                    select("#txt_detail_id").textIs("id=2")
                }.action {
                    tap("#btn_detail_next")
                }.expectation {
                    select("#txt_detail_id").textIs("id=3")
                }
            }
            scene(4, "アイコンだけの戻るを #id で押すと1つ戻る") {
                action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_detail_id").textIs("id=2")
                }
            }
            scene(5, "アイコンだけの戻るをラベル(contentDescription)で押す") {
                action {
                    tap("戻る")
                }.expectation {
                    select("#txt_screen_title").textIs("引数付き遷移")
                }
            }
        }
    }

    @Test("システムの戻る(back)で NavHost が1つ戻る")
    func S0020() {
        scenario {
            scene(1, "ページャへ") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_pager")
                }.expectation {
                    select("#txt_screen_title").textIs("ページャ")
                }
            }
            scene(2, "back で戻る") {
                action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EX ホーム")
                }
            }
        }
    }
}
