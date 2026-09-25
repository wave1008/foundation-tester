// Bench の作成フロー用フィクスチャ(Bench/tasks/ios-authoring-add-expectations-controls.json)。
// **操作だけがあり、expectation が空の下書き**。検証を書き足す盤面のうち、**素直に書くと外れる
// 検証がある**もの(ios-authoring-add-expectations では書こうとした検証が全部最初から合っていて、
// その場で確かめる手段(ft_verify)が効く場面が無かった):
//   - 自作チェックボックス #cb_agree は状態を a11y に出さない → checkIsON は通らない
//     (E2E-iOS は画像分類の見本で読んでいるが、このパッケージには見本が無い)。正は echo の agree=true
//   - スライダー #slider_volume の value は "50%"(パーセント表記)で、"50" ではない
// run のたびに mcp-bench.sh がこのファイルを一時パッケージへ置き直す(ここは編集されない)。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class コントロール {
    @Test("スイッチとチェックボックスを ON にできる")
    func S0010() {
        scenario {
            scene(1, "コントロール画面を開く") {
                condition { launchApp() }
                .action { tap("#tab_controls") }
                .expectation { }
            }
            scene(2, "スイッチとチェックボックスを ON にする") {
                action {
                    tap("#sw_notify")
                    tap("#cb_agree")
                }.expectation { }
            }
        }
    }
}
