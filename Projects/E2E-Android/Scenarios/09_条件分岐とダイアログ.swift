// 09_条件分岐とダイアログ.swift
// ftester 機能: `ifCanSelect`(出るか不定な要素への条件分岐)と `select`(掴めなければ空要素を返す)。
// #btn_maybe_dialog は奇数回目だけダイアログを開く決定的仕様のため、ifCanSelect の
// 「出ても出なくても通る」ことの検証材料になる。
// **`select` の空振り検証は S0010 の最終シーンへ統合した**(2026-08-04)。導入シーンが同一で、
// launchApp + ナビの固定費だけが増えていたため(全 E2E スイートは合計律速 =
// docs/performance-tuning.md §3.6)。**交互ダイアログ(S0020)は分離を維持する** ——
// #btn_maybe_dialog のカウンタは画面離脱でリセットされる仕様で、他の検証と同居させると
// 「何回目のタップか」がシーンの並びに依存するため。
// SUT のダイアログは AlertDialog + setView(カスタムビュー)。既定ボタンは resource-id が
// android:id/button1,button2 になり #btn_dialog_ok を引けないため、自前の id 付きボタンを載せている。
// 別ウィンドウでも View の resource-id はそのまま出るので #txt_dialog_title も引ける
// (iOS ネイティブは UIAlertController が id を捨てるため見出しをラベルで引く。ここが OS 差)。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
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
            scene(4, "ダイアログを閉じた状態で select しても scene は成功し、空要素が返る") {
                action {
                    select("#btn_dialog_ok", timeout: 0).isEmpty.thisIsTrue()
                }.expectation {
                    // select は掴めなくても失敗しないので、直前の結果が保たれたままであること
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

    @Test("back でダイアログが閉じる")
    func S0040() {
        scenario {
            scene(1, "ダイアログを開いて back で閉じる") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_dialog")
                    tap("#btn_show_dialog")
                }.expectation {
                    exist("#btn_dialog_ok")
                }.action {
                    // View/XML の AlertDialog は cancelable 既定 true なので back で閉じる。
                    // キーボード非表示の画面遷移直後なので back の1回目がダイアログに届く
                    back()
                }.expectation {
                    notExist("#btn_dialog_ok")
                }
            }
        }
    }
}
