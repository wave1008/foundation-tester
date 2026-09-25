// このファイルは ProjectScaffold.demoScenario(app: "com.example.scaffoldfixture") の出力と1文字も違わない
// (ScaffoldDemoScenarioTests が等号で固定する)。**置き場所がテストターゲットなので swift test がコンパイルする**
// = 雛形に廃止した書き方が残ると、受け手の最初のビルドより先にここで落ちる。雛形を変えたらここも貼り替える
// (貼り付け用の全文はテストの失敗メッセージが出す)。
// ---- ここから雛形の出力 ----
// sample_test.swift
// 雛形が置いたデモ。**消して構いません**(自分のシナリオを書き始めるときの雛形として使う)。
// コマンドの一覧と引数は docs/commands.md、書き方の流れは docs/user-docs/ を参照。

import FTDSL

// app: 対象アプリの bundle ID / package name。プロファイル
// (profiles/apps/*.json)とは独立にここで指定する。
// platform: を書くとその OS でだけ実行される(省略時は両方)。
@TestClass(app: "com.example.scaffoldfixture")
class デモ {

    @Test("アプリが起動して前面に出る")
    func S0010() {
        scenario {
            // scene = 画面。condition(前提)→ action(操作)→ expectation(検証)の順に書く。
            scene(1, "アプリを起動する") {
                condition {
                    launchApp()
                }.expectation {
                    appIs("com.example.scaffoldfixture")
                    screenshot("起動直後")
                }
            }

            // 以降は書き方の例。セレクタ("#id" や "テキスト")を自分のアプリのものに
            // 差し替えて有効化する。**セレクタは推測で書かない** —— `ft_snapshot`(MCP)か
            // `fleetest api snapshot` で実際の画面から採る。
            //
            // scene(2, "ログインする") {
            //     action {
            //         tap("#input_id")
            //         type("demo")
            //         tap("#btn_login")
            //     }.expectation {
            //         exist("#txt_home")
            //         select("#txt_user").textIs("demo")
            //     }
            // }
        }
    }
}
