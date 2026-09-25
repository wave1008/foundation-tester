// Bench の作成フロー用フィクスチャ(Bench/tasks/android-authoring-fix-late.json)。
// ios-authoring-fix-late の Android 版。**わざと古くしてある**: アプリ(E2EAppAndroid)は正しく、
// シナリオの**最後の段**で送信ボタンの id がずれている(正: #btn_input_submit)。そこへ着くには
// 起動から入力2つまで5〜6手が要るので、手で再現するより回して失敗時の要素一覧を読むほうが安い。
// 送信の前の hideKeyboard() は E2E-Android の 03 と同じ(背の低い画面ではキーボードが送信ボタンを
// 木から消す。容器はスクロールしないので scroll: では届かない)。
// run のたびに mcp-bench.sh がこのファイルを一時パッケージへ置き直す(ここは編集されない)。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class テキスト入力 {
    @Test("単一行とパスワードを入力して送信できる")
    func S0010() {
        scenario {
            scene(1, "入力画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_input")
                }.expectation {
                    select("#txt_echo_single").textIs("single=")
                }
            }
            scene(2, "単一行に入力する") {
                action {
                    tap("#field_single")
                    type("#field_single", "hello123")
                }.expectation {
                    select("#txt_echo_single").textIs("single=hello123")
                }
            }
            scene(3, "パスワードに入力する") {
                action {
                    tap("#field_password")
                    type("#field_password", "secret42")
                }.expectation {
                    select("#txt_echo_password").textIs("password=secret42")
                }
            }
            scene(4, "送信すると submitted に反映される") {
                action {
                    hideKeyboard()
                    tap("#btn_input_send")
                }.expectation {
                    select("#txt_input_submitted").textIs("submitted=hello123")
                }
            }
        }
    }
}
