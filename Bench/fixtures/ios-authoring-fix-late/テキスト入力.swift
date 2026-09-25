// Bench の作成フロー用フィクスチャ(Bench/tasks/ios-authoring-fix-late.json)。
// **わざと古くしてある**: アプリ(E2EAppIOS)は正しく、シナリオの**最後の段**で送信ボタンの id が
// ずれている(正: #btn_input_submit)。そこへ着くには起動から入力2つまで5〜6手が要るので、
// 手で再現するより、回して失敗時の要素一覧を読むほうが安い —— ft_run_scenario の失敗の返し方が
// 手数に出る盤面(ios-authoring-fix-drift は手前でずれているので、回す前に触って直せてしまう)。
// 失敗の文面は「id が見つからない」だけで、正しい id は要素一覧にしか載らない。
// run のたびに mcp-bench.sh がこのファイルを一時パッケージへ置き直す(ここは編集されない)。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class テキスト入力 {
    @Test("単一行とパスワードを入力して送信できる")
    func S0010() {
        scenario {
            scene(1, "入力画面を開く") {
                condition { launchApp() }
                .action { tap("#nav_input") }
                .expectation { select("#txt_echo_single").textIs("single=") }
            }
            scene(2, "単一行に入力する") {
                action {
                    tap("#field_single")
                    type("#field_single", "hello123")
                }.expectation { select("#txt_echo_single").textIs("single=hello123") }
            }
            scene(3, "パスワードに入力する") {
                action {
                    tap("#field_password")
                    type("#field_password", "secret42")
                }.expectation { select("#txt_echo_password").textIs("password=secret42") }
            }
            scene(4, "送信すると submitted に反映される") {
                action { tap("#btn_input_send") }
                .expectation { select("#txt_input_submitted").textIs("submitted=hello123") }
            }
        }
    }
}
