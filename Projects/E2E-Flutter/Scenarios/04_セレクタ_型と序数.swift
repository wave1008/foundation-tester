// 04_セレクタ_型と序数.swift
// ftester 機能: `.Type[n]`(序数)/ `.Type#id` / `.Type=ラベル`(型限定ラベル)/ `||`(フォールバック連鎖)。
//
// 序数の契約(iPhone 17 Pro/iOS 27.0 と Pixel 9/Android 15 の実スナップショットで採取):
// セレクタ画面の Button 順は 戻る(1) 許可(2) 通知を許可(3) 項目(4,5,6) 共通ラベル(7) 別名(8)
// 結果クリア(9) タブ(10-12)。よって3番目の『項目』= `.Button[6]`。**両 OS で同じ並び**。
//
// **Flutter は型語彙が OS で非対称**(実測):
//   - ボタン(`Semantics(button: true)` を持つノード)は iOS/Android とも `Button`
//   - **テキストは iOS = `StaticText` / Android = `Other`**(Flutter は canvas 描画で、
//     Android 側の className が android.view.View のままになるため StaticText に写像されない)
// → 型セレクタを使ってよいのは Button だけ。テキストの検証は必ず `#id` + `textIs` で書く。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class セレクタの型と序数とフォールバックが解決できること {

    @Test(".Type[n] 序数で同一ラベル3連から一意に引ける(ラベル指定では曖昧で引けない)")
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
                    // 既定(true)だと occlusion-guard が FM 視覚照合を呼び、Flutter の小さな
                    // テキスト領域を「覆われている」と誤判定して落ちることがある
                    // (実際には完全に見えている。2026-07-23 実測)。可視性の検証は 01 が行う。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    textIs("#txt_selector_result", "result=-")
                }
            }
            scene(2, ".Button[6] で3番目の『項目』(#btn_item_3)に着地") {
                action {
                    tap(".Button[6]")
                }.expectation {
                    textIs("#txt_selector_result", "result=item3")
                }
            }
        }
    }

    @Test(".Type#id で型限定した id 指定ができる")
    func S0020() {
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
                    // 既定(true)だと occlusion-guard が FM 視覚照合を呼び、Flutter の小さな
                    // テキスト領域を「覆われている」と誤判定して落ちることがある
                    // (実際には完全に見えている。2026-07-23 実測)。可視性の検証は 01 が行う。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    textIs("#txt_selector_result", "result=-")
                }
            }
            scene(2, ".Type#id で #btn_allow に着地") {
                action {
                    tap(".Button#btn_allow")
                }.expectation {
                    textIs("#txt_selector_result", "result=allow")
                }
            }
        }
    }

    @Test("|| フォールバック連鎖で1つ目が無くても2つ目に当たる")
    func S0030() {
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
                    // 既定(true)だと occlusion-guard が FM 視覚照合を呼び、Flutter の小さな
                    // テキスト領域を「覆われている」と誤判定して落ちることがある
                    // (実際には完全に見えている。2026-07-23 実測)。可視性の検証は 01 が行う。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    textIs("#txt_selector_result", "result=-")
                }
            }
            scene(2, "btn_alias_old(存在しない) || btn_alias_new(実在) → 2つ目で解決") {
                action {
                    tap("#btn_alias_old||#btn_alias_new")
                }.expectation {
                    textIs("#txt_selector_result", "result=alias")
                }
            }
        }
    }

    @Test(".Type=共通ラベル で同ラベルのテキストではなく Button が選ばれる")
    func S0040() {
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
                    // 既定(true)だと occlusion-guard が FM 視覚照合を呼び、Flutter の小さな
                    // テキスト領域を「覆われている」と誤判定して落ちることがある
                    // (実際には完全に見えている。2026-07-23 実測)。可視性の検証は 01 が行う。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    textIs("#txt_selector_result", "result=-")
                }
            }
            scene(2, ".Button=共通ラベル は #txt_shared_label ではなく #btn_shared_label に着地") {
                action {
                    tap(".Button=共通ラベル")
                }.expectation {
                    textIs("#txt_selector_result", "result=shared")
                }
            }
        }
    }
}
