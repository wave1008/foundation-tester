// 13_ディープリンク.swift
// fleetest 機能: `launchApp(url:)`(再起動→URL配送を1ステップで行う)/ `openURL`(起動済みアプリへの配送)。
// SUT は iOS ネイティブ(SwiftUI+UIKit)の E2EAppIOS。URL スキーム `fte2eios` はホームタブのスタックへ
// 積む形で着地する(`#btn_back` でホームへ戻る)。契約は E2EAppCMP/docs/ui-contract.md §ディープリンク。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class ディープリンクで意図した画面に遷移すること {

    @Test("launchApp(url:) で目的の画面から起動する")
    func S0010() {
        scenario {
            scene(1, "セレクタ画面の URL で起動すると、そこから始まる") {
                condition {
                    launchApp(url: "fte2eios://screen/selector")
                }.expectation {
                    select("#txt_screen_title").textIs("セレクタ")
                }
            }
            scene(2, "受け取った URL 全体がライフサイクル画面の echo に残る") {
                action {
                    tap("#btn_back")
                }.expectation {
                    exist("#txt_home_marker")
                }.action {
                    tap("#nav_lifecycle", scroll: .down)
                }.expectation {
                    select("#txt_last_deeplink").textIs("deeplink=fte2eios://screen/selector")
                }
            }
        }
    }

    @Test("openURL で起動済みアプリを別画面へ飛ばす(クエリ付き)")
    func S0020() {
        scenario {
            scene(1, "通常起動でホームに着地する") {
                condition {
                    launchApp()
                }.expectation {
                    exist("#txt_home_marker")
                }
            }
            scene(2, "クエリ付き URL を配送すると、クエリを含む URL 全体ごとライフサイクル画面へ着地する") {
                action {
                    openURL("fte2eios://screen/lifecycle?tag=a&n=1")
                }.expectation {
                    select("#txt_screen_title").textIs("ライフサイクル")
                    select("#txt_last_deeplink").textIs("deeplink=fte2eios://screen/lifecycle?tag=a&n=1")
                }
            }
        }
    }

    @Test("未知の URL は受け取るが画面遷移は起きない")
    func S0030() {
        scenario {
            scene(1, "ライフサイクル画面にいる状態を作る") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_lifecycle", scroll: .down)
                }.expectation {
                    exist("#txt_last_deeplink")
                }
            }
            scene(2, "未知の URL を配送しても画面は変わらず、受け取ったことだけが echo に残る") {
                action {
                    openURL("fte2eios://unknown/route")
                }.expectation {
                    select("#txt_screen_title").textIs("ライフサイクル")
                    select("#txt_last_deeplink").textIs("deeplink=fte2eios://unknown/route")
                }
            }
        }
    }
}
