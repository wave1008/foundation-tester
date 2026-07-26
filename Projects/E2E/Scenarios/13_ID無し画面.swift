// 13_ID無し画面.swift
// ftester 機能: **方向セレクタ(`:right` / `:left`)だけ**で id の無い画面を操作・検証する。
// 対象画面(ui-contract.md「ID なし画面」)の要素には testTag が一切無く、
// スイッチは無ラベル・行3のボタンは左右とも同じラベル `変更` なので、方向でしか選び分けられない。
// 型を使うセレクタは OS で型名が違う(Compose の Switch/Button は iOS=Switch/Button、
// Android=Cell)ため ios {} / android {} で分ける(ui-contract.md 全体規約)。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class ID無し画面を方向セレクタで操作できること {

    @Test("方向セレクタで id の無いスイッチとボタンを選び分ける")
    func S0010() {
        scenario {
            scene(1, "ID なし画面へ移動する") {
                condition {
                    launchApp()
                    tap("#nav_noid")
                }.expectation {
                    textIs("#txt_screen_title", "ID なし")
                    // 状態表示は id が無いので部分一致(`notify=` ⊂ `notify=off`)で引く
                    textIs("notify=", "notify=off")
                    textIs("location=", "location=off")
                    textIs("qty=", "qty=0")
                }
            }
            scene(2, "行1のスイッチだけが切り替わる(帯判定が隣の行を拾わない)") {
                action {
                    ios { tap(".switch:right(通知)") }
                    android { tap(".cell:right(通知)") }
                }.expectation {
                    textIs("notify=", "notify=on")
                    textIs("location=", "location=off")
                }
            }
            scene(3, "行2のスイッチを同じ記法で切り替える") {
                action {
                    ios { tap(".switch:right(位置情報)") }
                    android { tap(".cell:right(位置情報)") }
                }.expectation {
                    textIs("location=", "location=on")
                    textIs("notify=", "notify=on")
                }
            }
            scene(4, "同一ラベルのボタンを左右で選び分ける") {
                action {
                    ios { tap(".button=変更:right(数量)") }
                    android { tap(".cell=変更:right(数量)") }
                }.expectation {
                    textIs("qty=", "qty=1")
                }.action {
                    ios { tap(".button=変更:left(数量)") }
                    android { tap(".cell=変更:left(数量)") }
                }.expectation {
                    textIs("qty=", "qty=0")
                }
            }
            scene(5, "方向が違えば解決しない(最も近いものを勝手に選ばない)") {
                expectation {
                    // 通知ラベルの左にスイッチは無い。`:near` 時代はここで右のスイッチを拾っていた
                    ios { notExist(".switch:left(通知)") }
                    android { notExist(".cell:left(通知)") }
                }
            }
        }
    }
}
