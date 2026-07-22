// 04_セレクタ_型と序数.swift
// ftester 機能: `.Type[n]`(序数)/ `.Type#id` / `.Type=ラベル`(型限定ラベル)/ `||`(フォールバック連鎖)。
//
// 序数の契約(Pixel 9/Android 15 の実スナップショットで採取):
// `.Type[n]` は「**現在画面に見えている**同型要素をツリー順に数えた n 番目」。
// セレクタ画面の Button 順は 戻る(1) 許可(2) 通知を許可(3) 項目(4,5,6) 共通ラベル(7) 別名(8)
// 結果クリア(9) タブ(10-12)。よって3番目の『項目』= `.Button[6]`(iOS ネイティブ版と同じ並び)。
//
// **この SUT は同じアプリの中に View と Compose が同居する**のが検証の核:
//   - View の android.widget.Button → 型 `Button`
//   - Compose の Button(コントロール画面)→ 型 `Cell`(className が android.widget.Button にならず
//     SnapshotBuilder.mappedType の既定 clickable 側に落ちる)
// 同一アプリ内で型が食い違うため、型セレクタは「どの画面か」まで意識して書く必要がある。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class セレクタの型と序数とフォールバックが解決できること {

    @Test(".Type[n] 序数で同一ラベル3連から一意に引ける(ラベル指定では曖昧で引けない)")
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

    @Test(".Type=共通ラベル で同ラベルの Text ではなく Button が選ばれる")
    func S0040() {
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
            scene(2, ".Type=共通ラベル は #txt_shared_label(StaticText)ではなく #btn_shared_label(Button)に着地") {
                action {
                    tap(".Button=共通ラベル")
                }.expectation {
                    textIs("#txt_selector_result", "result=shared")
                }
            }
        }
    }

    @Test("同一アプリでも Compose 部分は Button ではなく Cell 型になる")
    func S0050() {
        scenario {
            scene(1, "コントロールタブ(ComposeView)を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_controls")
                }.expectation {
                    textIs("#txt_radio", "plan=A")
                }
            }
            scene(2, "Compose の Button は .Cell=ラベル で引ける(.Button では引けない)") {
                action {
                    tap("#radio_b")
                    tap(".Cell=コントロールリセット")
                }.expectation {
                    textIs("#txt_radio", "plan=A")
                }
            }
        }
    }
}
