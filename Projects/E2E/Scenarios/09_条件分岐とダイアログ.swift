// 09_条件分岐とダイアログ.swift
// ftester 機能: `ifCanSelect`(出るか不定な要素への条件分岐)と `select`(掴めなければ空要素を返す)。
// #btn_maybe_dialog は奇数回目だけダイアログを開く決定的仕様のため、ifCanSelect の
// 「出ても出なくても通る」ことの検証材料になる。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class 条件分岐とダイアログ操作が正しく働くこと {

    @Test("ダイアログの OK/キャンセルで結果が反映される")
    func S0010() {
        scenario {
            scene(1, "ダイアログ画面を開く") {
                condition {
                    launchApp()
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

    @Test("select の空振りは失敗せず空要素を返す")
    func S0030() {
        scenario {
            scene(1, "ダイアログ画面を開く(ダイアログを開かずに)") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_dialog")
                }.expectation {
                    textIs("#txt_dialog_result", "dialog=none")
                }
            }
            scene(2, "ダイアログ未表示のまま select しても scene は成功し、空要素が返る") {
                action {
                    select("#btn_dialog_ok", timeout: 0).isEmpty.thisIsTrue()
                }.expectation {
                    textIs("#txt_dialog_result", "dialog=none")
                }
            }
        }
    }

    @Test("back でダイアログが閉じる(Android のみ)")
    func S0040() {
        scenario {
            // すべて android {} で包む: iOS のエッジスワイプ back は本 SUT(独自ナビ)では観測不能
            // (docs/commands.md の back() 契約)。iOS 側でダイアログを開いたまま残すと後続シナリオを
            // 壊すため、iOS では何も実行しない
            scene(1, "ダイアログを開いて back で閉じる") {
                condition {
                    launchApp()
                }.action {
                    android {
                        tap("#nav_dialog")
                        tap("#btn_show_dialog")
                        exist("#btn_dialog_ok")
                        back()
                    }
                }.expectation {
                    android {
                        notExist("#btn_dialog_ok")
                    }
                }
            }
        }
    }
}
