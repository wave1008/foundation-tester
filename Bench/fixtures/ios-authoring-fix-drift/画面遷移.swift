// Bench の作成フロー用フィクスチャ(Bench/tasks/ios-authoring-fix-drift.json)。
// **わざと古くしてある**: アプリ(E2EAppIOS)は正しく、シナリオ側が2か所ずれている。
//   ① 遷移ボタンの id(正: #nav_selector)
//   ② セレクタ画面の見出しの期待値(正: "セレクタ")
// 1回目の実行は①で落ち、①を直すと②で落ちる。どちらも失敗時の要素一覧に正解が載る。
// run のたびに mcp-bench.sh がこのファイルを一時パッケージへ置き直す(ここは編集されない)。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class 画面遷移 {
    @Test("セレクタ画面へ遷移して戻れる")
    func S0010() {
        scenario {
            scene(1, "起動するとホームが出る") {
                condition { launchApp() }
                .expectation { select("#txt_screen_title").textIs("ホーム") }
            }
            scene(2, "セレクタ画面へ遷移して戻る") {
                action { tap("#nav_selectors") }
                .expectation { select("#txt_screen_title").textIs("Selector") }
                .action { tap("#btn_back") }
                .expectation { select("#txt_screen_title").textIs("ホーム") }
            }
        }
    }
}
