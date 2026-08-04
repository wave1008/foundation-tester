// 04_セレクタ_型と序数.swift
// ftester 機能: `.型[n]`(序数)/ `.型#id` / `.型&&ラベル`(型限定ラベル)/ `||`(フォールバック連鎖)。
//
// 序数の契約(iPhone 17 Pro/iOS 27.0 と Pixel 9/Android 15 の実スナップショットで採取):
// セレクタ画面の Button 順は 戻る(1) 許可(2) 通知を許可(3) 項目(4,5,6) 共通ラベル(7) 別名(8)
// 結果クリア(9) タブ(10-12)。よって3番目の『項目』= `.button[6]`。**両 OS で同じ並び**。
//
// **Flutter は型語彙が OS で非対称**(実測):
//   - ボタン(`Semantics(button: true)` を持つノード)は iOS/Android とも `Button`
//   - **テキストは iOS = `StaticText` / Android = `Other`**(Flutter は canvas 描画で、
//     Android 側の className が android.view.View のままになるため StaticText に写像されない)
// → 型セレクタを使ってよいのは Button だけ。テキストの検証は必ず `#id` + `textIs` で書く。
//
// **記法ごとに @Test を分けない**(2026-08-04 統合)。4 本は同じセレクタ画面で始まり導入シーンが
// 完全に同一で、1 本あたり launchApp + ナビの固定費だけが増えていた。全 E2E スイートは合計律速
// (合計÷レーン数 > 最長シナリオ)なので、@Test を減らすと壁時計が縮む
// (docs/performance-tuning.md §3.6 の判定表)。**空振りは検出できる** —— 各シーンの期待値は
// 直前と必ず異なる値(`-` → item3 → allow → alias → shared)なので、タップが届かなければ落ちる。
// 統合で、下の起動直後同期(4 か所に複製されていた)も 1 か所に減る。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class セレクタの型と序数とフォールバックが解決できること {

    @Test("序数・型限定 id・型限定ラベル・フォールバック連鎖が同じ画面で解決できる")
    func S0010() {
        scenario {
            scene(1, "セレクタ画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(2, ".button[6] で3番目の『項目』(#btn_item_3)に着地") {
                action {
                    tap(".button[6]")
                }.expectation {
                    select("#txt_selector_result").textIs("result=item3")
                }
            }
            scene(3, ".型#id で #btn_allow に着地") {
                action {
                    tap(".button#btn_allow")
                }.expectation {
                    select("#txt_selector_result").textIs("result=allow")
                }
            }
            scene(4, "btn_alias_old(存在しない) || btn_alias_new(実在) → 2つ目で解決") {
                action {
                    tap("#btn_alias_old||#btn_alias_new")
                }.expectation {
                    select("#txt_selector_result").textIs("result=alias")
                }
            }
            scene(5, ".button&&共通ラベル は #txt_shared_label ではなく #btn_shared_label に着地") {
                action {
                    tap(".button&&共通ラベル")
                }.expectation {
                    select("#txt_selector_result").textIs("result=shared")
                }
            }
        }
    }
}
