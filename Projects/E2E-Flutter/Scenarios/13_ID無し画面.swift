// 13_ID無し画面.swift
// ftester 機能: **方向セレクタ(`:right` / `:left`)だけ**で id の無い画面を操作・検証する。
// 対象画面(E2EApp/docs/ui-contract.md「ID なし画面」)の要素には id が一切無く、
// スイッチは無ラベル・行3のボタンは左右とも同じラベル `変更` なので、方向でしか選び分けられない。
// **この SUT に置く意味**: 方向判定は frame(座標)に依存するので、レイアウトの実装が変われば
// 当たり外れが変わる。記法が4フレームワーク共通で通ることを確かめる。
// Flutter は Switch/Button とも iOS/Android 同型(<SUT>/docs/ui-contract.md 表 B)なので型の分岐は不要。
// **本体を ios {} で括っているのは Flutter/Android の制約**: id の無いテキストがスナップショットに
// 出ない(className=android.view.View + resource-id 無し → ブリッジの shouldInclude が落とす)ため、
// アンカーになるラベル(`通知` 等)が引けない。クラスごと platform: "ios" に固定すると
// android プロファイルの一括実行で「担当ワーカーがありません」= 失敗になるので、この形にしてある。
// ブリッジの型正規化(docs/design.md §10 のフェーズ2)で解消したら android {} 側も同じ検証に揃える。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class ID無し画面を方向セレクタで操作できること {

    @Test("方向セレクタで id の無いスイッチとボタンを選び分ける")
    func S0010() {
        scenario {
            scene(1, "ID なし画面へ移動する") {
                condition {
                    launchApp()
                    tap("#nav_noid")
                }.expectation {
                    // 画面タイトルはシェル要素で id があるため両 OS で引ける
                    textIs("#txt_screen_title", "ID なし")
                    // 状態表示は id が無いので部分一致(`notify=` ⊂ `notify=off`)で引く
                    ios {
                        textIs("notify=", "notify=off")
                        textIs("location=", "location=off")
                        textIs("qty=", "qty=0")
                    }
                }
            }
            scene(2, "行1のスイッチだけが切り替わる(帯判定が隣の行を拾わない)") {
                action {
                    ios { tap(".switch:right(通知)") }
                }.expectation {
                    ios {
                        textIs("notify=", "notify=on")
                        textIs("location=", "location=off")
                    }
                }
            }
            scene(3, "行2のスイッチを同じ記法で切り替える") {
                action {
                    ios { tap(".switch:right(位置情報)") }
                }.expectation {
                    ios {
                        textIs("location=", "location=on")
                        textIs("notify=", "notify=on")
                    }
                }
            }
            scene(4, "同一ラベルのボタンを左右で選び分ける") {
                action {
                    ios { tap(".button=変更:right(数量)") }
                }.expectation {
                    ios { textIs("qty=", "qty=1") }
                }.action {
                    ios { tap(".button=変更:left(数量)") }
                }.expectation {
                    ios { textIs("qty=", "qty=0") }
                }
            }
            scene(5, "方向が違えば解決しない(最も近いものを勝手に選ばない)") {
                expectation {
                    // 通知ラベルの左にスイッチは無い。`:near` 時代はここで右のスイッチを拾っていた
                    ios { notExist(".switch:left(通知)") }
                }
            }
        }
    }
}
