// 01_ナビゲーション.swift
// 確かめる癖: SwiftUI の NavigationStack(値つきの遷移・積み重ね)・システムの戻るボタン(#BackButton。
// ラベルは前の画面のタイトル)・エッジスワイプの戻る。契約は E2EXAppCMP/docs/ui-contract.md と E2EXAppIOS/docs/ui-contract.md。

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
            scene(4, "システムの戻るボタン(#BackButton)で1つ戻る") {
                action {
                    tap("#BackButton")
                }.expectation {
                    select("#txt_detail_id").textIs("id=2")
                }
            }
            scene(5, "もう一度戻る") {
                action {
                    tap("#BackButton")
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
