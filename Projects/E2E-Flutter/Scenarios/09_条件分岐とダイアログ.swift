// 09_条件分岐とダイアログ.swift
// ftester 機能: `ifCanSelect`(出るか不定な要素への条件分岐)と `optional:`(空振りしても失敗にしない)。
// #btn_maybe_dialog は奇数回目だけダイアログを開く決定的仕様のため、ifCanSelect の
// 「出ても出なくても通る」ことの検証材料になる。
// SUT のダイアログは Flutter の AlertDialog(Navigator のオーバーレイ)。ネイティブのダイアログ
// ウィンドウではないため、見出しもボタンも通常の Semantics として出る
// = #txt_dialog_title が両 OS で引ける(iOS ネイティブ SUT では引けない。ここが差)。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class 条件分岐とダイアログ操作が正しく働くこと {

    @Test("ダイアログの OK/キャンセルで結果が反映される")
    func S0010() {
        scenario {
            scene(1, "ダイアログ画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    exist("#txt_home_marker")
                }.action {
                    tap("#nav_dialog")
                }.expectation {
                    textIs("#txt_dialog_result", "dialog=none")
                }
            }
            scene(2, "ダイアログを開いて OK") {
                action {
                    tap("#btn_show_dialog")
                }.expectation {
                    exist("#txt_dialog_title")
                }.action {
                    tap("#btn_dialog_ok")
                }.expectation {
                    textIs("#txt_dialog_result", "dialog=ok")
                }
            }
            scene(3, "再度開いてキャンセル") {
                action {
                    tap("#btn_show_dialog")
                }.expectation {
                    exist("#txt_dialog_title")
                }.action {
                    tap("#btn_dialog_cancel")
                }.expectation {
                    textIs("#txt_dialog_result", "dialog=cancel")
                }
            }
        }
    }

    @Test("ifCanSelect は出ても出なくても通る(交互ダイアログ)")
    func S0020() {
        scenario {
            scene(1, "ダイアログ画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    exist("#txt_home_marker")
                }.action {
                    tap("#nav_dialog")
                }.expectation {
                    textIs("#txt_dialog_result", "dialog=none")
                }
            }
            scene(2, "1回目(奇数回目=開く)。ifCanSelect が成立してキャンセルする") {
                action {
                    tap("#btn_maybe_dialog")
                    // 出るか不定なダイアログを ifCanSelect で待って処理する。ここが本シナリオの検証点:
                    // 成立/不成立のどちらでも scene は失敗にならない
                    ifCanSelect("#btn_dialog_cancel", waitSeconds: 1) {
                        tap("#btn_dialog_cancel")
                    }
                }.expectation {
                    exist("#txt_dialog_result")
                }
            }
            scene(3, "2回目(偶数回目=開かない)。ifCanSelect が不成立でもそのまま通る") {
                action {
                    tap("#btn_maybe_dialog")
                    ifCanSelect("#btn_dialog_cancel", waitSeconds: 1) {
                        tap("#btn_dialog_cancel")
                    }
                }.expectation {
                    exist("#txt_dialog_result")
                }
            }
        }
    }

    @Test("optional: true の空振りは失敗にならない")
    func S0030() {
        scenario {
            scene(1, "ダイアログ画面を開く(ダイアログを開かずに)") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    exist("#txt_home_marker")
                }.action {
                    tap("#nav_dialog")
                }.expectation {
                    textIs("#txt_dialog_result", "dialog=none")
                }
            }
            scene(2, "ダイアログ未表示のまま optional: true で空振りしても scene は成功する") {
                action {
                    tap("#btn_dialog_ok", optional: true, timeout: 0)
                }.expectation {
                    textIs("#txt_dialog_result", "dialog=none")
                }
            }
        }
    }
}
