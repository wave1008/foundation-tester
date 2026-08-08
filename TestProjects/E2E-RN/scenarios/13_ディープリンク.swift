// 13_ディープリンク.swift
// ftester 機能: `launchApp(url:)`(再起動→URL配送を1ステップで行う)/ `openURL`(起動済みアプリへの配送)。
// SUT は React Native(RN 標準 `Linking`。iOS = SceneDelegate + RCTLinkingManager、
// Android = singleTop + onNewIntent)の E2EAppRN。URL スキーム `fte2ern` はホームタブのスタックへ
// 積む形で着地する(`#btn_back` でホームへ戻る)。契約は E2EAppCMP/docs/ui-contract.md §ディープリンク。
// platform 未指定 = ios/android 両方で回す(E2EAppRN/docs/ui-contract.md)。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class ディープリンクで意図した画面に遷移すること {

    @Test("launchApp(url:) で目的の画面から始まる")
    func S0010() {
        scenario {
            scene(1, "セレクタ画面への URL を渡して起動すると、その画面から始まる") {
                condition {
                    launchApp(url: "fte2ern://screen/selector")
                }.expectation {
                    select("#txt_screen_title").textIs("セレクタ")
                }
            }
            scene(2, "受け取った URL はライフサイクル画面の #txt_last_deeplink に残る") {
                action {
                    tap("#btn_back")
                }.expectation {
                    exist("#txt_home_marker")
                }.action {
                    tap("#nav_lifecycle")
                }.expectation {
                    select("#txt_last_deeplink").textIs("deeplink=fte2ern://screen/selector")
                }
            }
        }
    }

    @Test("openURL で起動済みアプリを別画面へ飛ばす(クエリ付き)")
    func S0020() {
        scenario {
            scene(1, "通常起動でホームにいる状態を作る") {
                condition {
                    launchApp()
                }.expectation {
                    exist("#txt_home_marker")
                }
            }
            scene(2, "クエリ付き URL を配送するとライフサイクル画面へ飛び、URL 全体が表示される") {
                action {
                    openURL("fte2ern://screen/lifecycle?tag=a&n=1")
                }.expectation {
                    select("#txt_screen_title").textIs("ライフサイクル")
                    select("#txt_last_deeplink").textIs("deeplink=fte2ern://screen/lifecycle?tag=a&n=1")
                }
            }
        }
    }

    @Test("未知の URL は届くが遷移しない")
    func S0030() {
        scenario {
            scene(1, "ライフサイクル画面にいる状態を作る") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_lifecycle")
                }.expectation {
                    exist("#txt_last_deeplink")
                }
            }
            scene(2, "未知の URL を配送しても画面は変わらず、URL だけ記録される") {
                action {
                    openURL("fte2ern://unknown/route")
                }.expectation {
                    select("#txt_screen_title").textIs("ライフサイクル")
                    select("#txt_last_deeplink").textIs("deeplink=fte2ern://unknown/route")
                }
            }
        }
    }
}
