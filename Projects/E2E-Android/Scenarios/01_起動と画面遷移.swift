// 01_起動と画面遷移.swift
// ftester 機能: launchApp / タブ切替 / 下位画面遷移+戻る / タブ切替時にスタックが
// 持ち越されないことの検証。
// SUT は Android ネイティブ(View/XML + 一部 Compose)の E2EAppAndroid。MainActivity は
// savedInstanceState を捨てるため「起動時は必ずホームタブのルート」契約が成立する
// (E2EAppAndroid/docs/ui-contract.md)。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class 起動と画面遷移が正しく行われること {

    @Test("起動・下位画面遷移・タブ切替の一連が正しく動く")
    func S0010() {
        scenario {
            scene(1, "起動時にホームのルートへ着地する") {
                condition {
                    launchApp()
                }.expectation {
                    exist("#txt_home_marker")
                    textIs("#txt_screen_title", "ホーム")
                }
            }
            scene(2, "下位画面へ遷移して戻るでホームに戻る") {
                action {
                    tap("#nav_selector")
                }.expectation {
                    textIs("#txt_screen_title", "セレクタ")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    textIs("#txt_screen_title", "ホーム")
                }
            }
            scene(3, "下位画面に入った状態でタブ切替してもスタックが持ち越されない") {
                action {
                    tap("#nav_selector")
                }.expectation {
                    textIs("#txt_screen_title", "セレクタ")
                }.action {
                    tap("#tab_controls")
                }.expectation {
                    textIs("#txt_screen_title", "コントロール")
                }.action {
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker")
                }
            }
            scene(4, "情報タブへ着地しアプリ ID が表示される") {
                action {
                    tap("#tab_about")
                }.expectation {
                    exist("#txt_about_marker")
                    textIs("#txt_about_app", "app=com.ftester.e2e.android")
                }
            }
        }
    }
}
