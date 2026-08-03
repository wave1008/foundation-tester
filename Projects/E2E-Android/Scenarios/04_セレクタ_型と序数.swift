// 04_セレクタ_型と序数.swift
// ftester 機能: `.型[n]`(序数)/ `.型#id` / `.型&&ラベル`(型限定ラベル)/ `||`(フォールバック連鎖)。
//
// 序数の契約(Pixel 9/Android 15 の実スナップショットで採取):
// `.型[n]` は「**現在画面に見えている**同型要素をツリー順に数えた n 番目」。
// セレクタ画面の Button 順は 戻る(1) 許可(2) 通知を許可(3) 項目(4,5,6) 共通ラベル(7) 別名(8)
// 結果クリア(9) タブ(10-12)。よって3番目の『項目』= `.button[6]`(iOS ネイティブ版と同じ並び)。
//
// **この SUT は同じアプリの中に View と Compose が同居する**のが検証の核:
//   - View の android.widget.button → 型 `Button`
//   - Compose の Button(コントロール画面)→ 型 `Cell`(className が android.widget.button にならず
//     SnapshotBuilder.mappedType の既定 clickable 側に落ちる)
// 同一アプリ内で型が食い違うため、型セレクタは「どの画面か」まで意識して書く必要がある。
//
// **記法ごとに @Test を分けない**(2026-08-04 統合)。5 本のうち 4 本は同じセレクタ画面で始まり
// 導入シーンが完全に同一で、1 本あたり launchApp + ナビの固定費だけが増えていた。全 E2E スイートは
// 合計律速(合計÷レーン数 > 最長シナリオ)なので、@Test を減らすと壁時計が縮む
// (docs/performance-tuning.md §3.6 の判定表)。**空振りは検出できる** —— 各シーンの期待値は
// 直前と必ず異なる値(`-` → item3 → allow → alias → shared)なので、タップが届かなければ落ちる。
// 最後の Compose 節だけはコントロールタブへ移るので、そこで画面が変わることを scene 見出しに残す。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class セレクタの型と序数とフォールバックが解決できること {

    @Test("序数・型限定 id・型限定ラベル・フォールバック連鎖と、View/Compose の型差")
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
            scene(6, "コントロールタブ(ComposeView)へ移ると Compose の Button は .clickable でしか引けない") {
                condition {
                    tap("#tab_controls")
                }.expectation {
                    textIs("#txt_radio", "plan=A")
                }.action {
                    tap("#radio_b")
                }.expectation {
                    // **途中で確定させる**: 省くと最後の plan=A が初期値のままでも通り、
                    // ラジオもリセットも空振りした場合と区別がつかない
                    textIs("#txt_radio", "plan=B")
                }.action {
                    tap(".clickable&&コントロールリセット")
                }.expectation {
                    textIs("#txt_radio", "plan=A")
                }
            }
        }
    }
}
