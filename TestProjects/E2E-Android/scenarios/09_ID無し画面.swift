// 09_ID無し画面.swift
// ftester 機能: **相対セレクタ(`基準:rightSwitch` / `基準:leftButton`)だけ**で id の無い画面を
// 操作・検証する。
// 対象画面(E2EAppCMP/docs/ui-contract.md「ID なし画面」)の要素には id が一切無く、
// スイッチは無ラベル・行3のボタンは左右とも同じラベル `変更` なので、方向でしか選び分けられない。
// **この SUT に置く意味**: 方向判定は frame(座標)に依存するので、レイアウトの実装が変われば
// 当たり外れが変わる。記法が4フレームワーク共通で通ることを確かめる。
// 型名は View/XML 実装の実測値(Switch/Button がそのまま出る。<SUT>/docs/ui-contract.md)。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class ID無し画面を方向セレクタで操作できること {

    @Test("方向セレクタで id の無いスイッチとボタンを選び分ける")
    func S0010() {
        scenario {
            scene(1, "ID なし画面へ移動する") {
                condition {
                    launchApp()
                    tap("#nav_noid")
                }.expectation {
                    select("#txt_screen_title").textIs("ID なし")
                    // 状態表示は id が無いので前方一致(`notify=*` が `notify=off` に当たる)で引く
                    select("notify=*").textIs("notify=off")
                    select("location=*").textIs("location=off")
                    select("qty=*").textIs("qty=0")
                }
            }
            scene(2, "行1のスイッチだけが切り替わる(帯判定が隣の行を拾わない)") {
                action {
                    tap("通知:rightSwitch")
                }.expectation {
                    select("notify=*").textIs("notify=on")
                    select("location=*").textIs("location=off")
                }
            }
            scene(3, "行2のスイッチを同じ記法で切り替える") {
                action {
                    tap("位置情報:rightSwitch")
                }.expectation {
                    select("location=*").textIs("location=on")
                    select("notify=*").textIs("notify=on")
                }
            }
            scene(4, "同一ラベルのボタンを左右で選び分ける") {
                action {
                    tap("数量:right(.button&&変更)")
                }.expectation {
                    select("qty=*").textIs("qty=1")
                }.action {
                    tap("数量:leftButton")
                }.expectation {
                    select("qty=*").textIs("qty=0")
                }
            }
            scene(5, "方向が違えば解決しない(最も近いものを勝手に選ばない)") {
                expectation {
                    // 通知ラベルの左にスイッチは無い。`:near` 時代はここで右のスイッチを拾っていた
                    notExist("通知:leftSwitch")
                }
            }
        }
    }
}
