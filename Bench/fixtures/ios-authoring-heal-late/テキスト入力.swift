// Bench の作成フロー用フィクスチャ(Bench/tasks/ios-authoring-heal-late.json)。
// ios-authoring-fix-late と同じシナリオ(最後の段で送信ボタンの id が古い: 正は #btn_input_submit)に、
// **アプリがまだ古い id だった頃に記録された指紋の控え**(fleetest/locator-fingerprints.json)を
// 同梱する = 「アプリ側で id だけが変わった」状況の再現。heal: true で回すと指紋照合(type+label)で
// 送信ボタンに解決して通り(🔧)、修正提案が出る。問うのは「修復に頼らない形へ直す」までの往復。
// **控えの鍵は行番号を含む**ので、この .swift の行を動かしたら控えの鍵も直す。
// run のたびに mcp-bench.sh がこのファイルと控えを一時パッケージへ置き直す(ここは編集されない)。

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
