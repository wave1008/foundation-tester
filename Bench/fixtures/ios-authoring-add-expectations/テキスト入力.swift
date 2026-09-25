// Bench の作成フロー用フィクスチャ(Bench/tasks/ios-authoring-add-expectations.json)。
// **操作だけがあり、expectation が空の下書き**(ft_draft_scenario が返す形。アサーションは推測で
// 書かないので空で返る)。エージェントは各 scene の操作の結果を確かめる検証を書き足して通す。
// 書いた検証が正しいかは、今はデバイスで回すまで分からない —— その場で確かめる手段
// (ft_verify 等)が手数に出るかを測る盤面。
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
                .expectation { }
            }
            scene(2, "単一行に入力する") {
                action {
                    tap("#field_single")
                    type("#field_single", "hello123")
                }.expectation { }
            }
            scene(3, "パスワードに入力する") {
                action {
                    tap("#field_password")
                    type("#field_password", "secret42")
                }.expectation { }
            }
            scene(4, "送信する") {
                action { tap("#btn_input_submit") }
                .expectation { }
            }
        }
    }
}
