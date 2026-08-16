// 17_ディープリンク.swift
// ftester 機能: `launchApp(url:)`(再起動 → URL 配送を1ステップで行う)/ `openURL`(起動済み
// アプリへ URL を送る)。スキーム `fte2ecmp` の契約は E2EAppCMP/docs/ui-contract.md §ディープリンク。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class ディープリンクで画面遷移と受信記録が正しく働くこと {

    @Test("launchApp(url:) で目的の画面から始まる")
    func S0010() {
        scenario {
            scene(1, "セレクタ画面への URL でプロセスを起動する") {
                condition {
                    launchApp(url: "fte2ecmp://screen/selector")
                }.expectation {
                    select("#txt_screen_title").textIs("セレクタ")
                }
            }
            scene(2, "戻ってライフサイクル画面で受信 URL が記録されていることを確認") {
                action {
                    tap("#btn_back")
                }.expectation {
                    exist("#txt_home_marker")
                }.action {
                    tap("#nav_lifecycle")
                }.expectation {
                    select("#txt_last_deeplink").textIs("deeplink=fte2ecmp://screen/selector")
                }
            }
        }
    }

    @Test("openURL で起動済みアプリを別画面へ飛ばす(クエリ付き)")
    func S0020() {
        scenario {
            scene(1, "通常起動してホームに着地") {
                condition {
                    launchApp()
                }.expectation {
                    exist("#txt_home_marker")
                }
            }
            scene(2, "クエリ付き URL を起動済みアプリへ送るとライフサイクル画面へ飛び、URL全体が記録される") {
                action {
                    openURL("fte2ecmp://screen/lifecycle?tag=a&n=1")
                }.expectation {
                    select("#txt_screen_title").textIs("ライフサイクル")
                    select("#txt_last_deeplink").textIs("deeplink=fte2ecmp://screen/lifecycle?tag=a&n=1")
                }
            }
        }
    }

    @Test("未知の URL は届くが遷移しない")
    func S0030() {
        scenario {
            scene(1, "ライフサイクル画面を開いておく") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_lifecycle")
                }.expectation {
                    exist("#txt_last_deeplink")
                }
            }
            scene(2, "未知のルートを送っても画面は変わらず、受信したことだけ記録される") {
                action {
                    openURL("fte2ecmp://unknown/route")
                }.expectation {
                    select("#txt_screen_title").textIs("ライフサイクル")
                    select("#txt_last_deeplink").textIs("deeplink=fte2ecmp://unknown/route")
                }
            }
        }
    }
}
