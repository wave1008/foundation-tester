// 04_セレクタ_型と序数.swift
// ftester 機能: `.型[n]`(序数)/ `.型#id` / `.型&&ラベル`(型限定ラベル)/ `||`(フォールバック連鎖)。
//
// 序数の契約(iPhone 17 Pro/iOS 27.0・xcuitest ブリッジの実スナップショットで採取):
// `.型[n]` は「**現在画面に見えている**同型要素をツリー順に数えた n 番目」。圧縮スナップショットは
// 画面外要素を含まないため、序数は**スクロール位置と画面クロム(戻る・下部タブ)に依存する**。
// セレクタ画面の Button 順は 戻る(1) 許可(2) 通知を許可(3) 項目(4,5,6) 共通ラベル(7) 別名(8)
// 結果クリア(9) タブ(10-12)。よって3番目の『項目』= `.button[6]`。
// **iOS ネイティブでは SwiftUI Button の型はそのまま `Button`**(Compose 版が Android で `Cell` に
// 落ちるのと違い、型名の OS 差を吸収する ios{}/android{} 分岐が要らない)。
//
// **記法ごとに @Test を分けない**(2026-08-04 統合)。4 本は同じセレクタ画面で始まり導入シーンが
// 完全に同一で、1 本あたり launchApp + ナビの固定費(iOS xcuitest 実測 約 4.7 秒)だけが増えていた。
// 全 E2E スイートは合計律速(合計÷レーン数 > 最長シナリオ)なので、@Test を減らすと壁時計が縮む
// (docs/performance-tuning.md §3.6 の判定表)。**空振りは検出できる** —— 各シーンの期待値は
// 直前と必ず異なる値(`-` → item3 → allow → alias → shared)なので、タップが届かなければ落ちる。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class セレクタの型と序数とフォールバックが解決できること {

    @Test("序数・型限定 id・型限定ラベル・フォールバック連鎖が同じ画面で解決できる")
    func S0010() {
        scenario {
            scene(1, "セレクタ画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    textIs("#txt_selector_result", "result=-")
                }
            }
            scene(2, ".button[6] で3番目の『項目』(#btn_item_3)に着地") {
                action {
                    tap(".button[6]")
                }.expectation {
                    textIs("#txt_selector_result", "result=item3")
                }
            }
            scene(3, ".型#id で #btn_allow に着地") {
                action {
                    tap(".button#btn_allow")
                }.expectation {
                    textIs("#txt_selector_result", "result=allow")
                }
            }
            scene(4, "btn_alias_old(存在しない) || btn_alias_new(実在) → 2つ目で解決") {
                action {
                    tap("#btn_alias_old||#btn_alias_new")
                }.expectation {
                    textIs("#txt_selector_result", "result=alias")
                }
            }
            scene(5, ".型&&共通ラベル は #txt_shared_label(staticText)ではなく #btn_shared_label(button)に着地") {
                action {
                    tap(".button&&共通ラベル")
                }.expectation {
                    textIs("#txt_selector_result", "result=shared")
                }
            }
        }
    }
}
