// 19_WebView.swift
// ftester 機能: **WebView(Web コンテンツ)の中を操作・検証できること**。
// 対象画面(E2EApp/docs/ui-contract.md「WebView 画面」)はネイティブの WebView に同じ HTML を
// 読ませたもので、他の画面と違い **`#id` が一切効かない**(HTML の id は a11y の identifier に
// 現れない)。指せるのは表示テキスト・`aria-label`・型だけ。
// **この SUT に置く意味**: iOS の WKWebView は中身の a11y が別プロセスにあり、in-app からは
// 見えない。uikit ホストでは ftester が DOM を JS で読む(InAppWebViewDOM)経路が主役になるので、
// その経路の実地検証を兼ねる(`--ios-inapp` で回さないとこの経路は一切通らない)。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class WebViewの中身を操作できること {

    @Test("WebView 内のリンク・入力・ボタンを操作し結果を検証する")
    func S0010() {
        scenario {
            scene(1, "WebView 画面へ移動する") {
                condition {
                    launchApp()
                    tap("#nav_webview")
                }.expectation {
                    textIs("#txt_screen_title", "WebView")
                    // **中身が出るまで数秒かかる**(WebContent プロセスの a11y 起動待ち。
                    // 実測 約2.3秒、SUT により最大 約8秒)。既定 5 秒では足りないことがある
                    exist("WebView 見出し", timeout: 20)
                    exist(".webView")
                    textIs("wv_result=*", "wv_result=-")
                }
            }
            // 既定 timeout のままにしておくこと: Android ブリッジが WebView 内ノードを
            // refresh() してから読む修正の**退行検知**を兼ねている(外すと a11y が 4〜8 秒古いまま
            // 返り、ここが間欠的に落ちる。SnapshotBuilder.collect のコメント参照)
            scene(2, "Web のリンクをタップする(型で絞らないと同ラベルの staticText と衝突する)") {
                action {
                    tap(".link&&WebView リンク")
                }.expectation {
                    textIs("wv_result=*", "wv_result=link")
                }
            }
            scene(3, "Web の入力欄へ入力し、送信ボタンで反映する") {
                action {
                    // 入力欄は id もラベルも持たない。placeholder フィルタで指す
                    // (素の文字列セレクタは text/label にしか当たらない)
                    type("placeholder=WebView 入力", "hello123")
                    tap("送信")
                }.expectation {
                    textIs("wv_result=*", "wv_result=hello123")
                }
            }
            scene(4, "aria-label だけのボタンもラベルで指せる") {
                action {
                    tap("WebView アリアラベル")
                }.expectation {
                    textIs("wv_result=*", "wv_result=aria")
                }
            }
            scene(5, "Web コンテンツ内をスクロール探索できる") {
                action {
                    scrollTo("WebView 画面外テキスト", maxSwipes: 15)
                }.expectation {
                    exist("WebView 画面外テキスト")
                }
            }
            scene(6, "WebView から離れるとネイティブ側の操作に戻れる") {
                action {
                    tap("#btn_back")
                }.expectation {
                    textIs("#txt_screen_title", "ホーム")
                    exist("#txt_home_marker")
                }
            }
        }
    }
}
