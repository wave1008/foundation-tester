// 07_条件分岐とダイアログ.swift
// ftester 機能: ダイアログの OK/キャンセル・`ifCanSelect`(出るか不定な要素への条件分岐)・
// `select`(掴めなければ空要素を返す)・back でのダイアログクローズ・`repeatWhileCanSelect`・
// `waitForClose` をまとめて検証する。
// #btn_maybe_dialog は奇数回目だけダイアログを開く決定的仕様のため、ifCanSelect / repeatWhileCanSelect の
// 「出ても出なくても通る」ことの検証材料になる。**カウンタは画面離脱で 0 に戻る**
// (ホームタブの子画面はナビのたびに View を作り直すため。MainActivity.kt の navigate/render 参照)。
// この統合クラスタは旧シナリオ境界を tap("#tab_home") + 再ナビへ置き換えているため、
// 各ブロックの1回目の #btn_maybe_dialog タップは常に奇数回目(=開く)として振る舞う。
// SUT のダイアログは AlertDialog + setView(カスタムビュー)。既定ボタンは resource-id が
// android:id/button1,button2 になり #btn_dialog_ok を引けないため、自前の id 付きボタンを載せている。
// 別ウィンドウでも View の resource-id はそのまま出るので #txt_dialog_title も引ける
// (iOS ネイティブは UIAlertController が id を捨てるため見出しをラベルで引く。ここが OS 差)。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class 条件分岐とダイアログ操作が正しく働くこと {

    @Test("ダイアログの OK/キャンセルで結果が反映される・ifCanSelect の交互ダイアログ・back クローズ・repeatWhileCanSelect・waitForClose")
    func S0010() {
        scenario {
            scene(1, "09.S0010: ダイアログの OK/キャンセルで結果が反映される") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=none")
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
                    select("#txt_dialog_result").textIs("dialog=ok")
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
                    select("#txt_dialog_result").textIs("dialog=cancel")
                }
            }
            scene(4, "ダイアログを閉じた状態で select しても scene は成功し、空要素が返る") {
                action {
                    select("#btn_dialog_ok", timeout: 0).isEmpty.thisIsTrue()
                }.expectation {
                    // select は掴めなくても失敗しないので、直前の結果が保たれたままであること
                    select("#txt_dialog_result").textIs("dialog=cancel")
                }
            }
            scene(5, "09.S0020: ifCanSelect は出ても出なくても通る(交互ダイアログ)") {
                condition {
                    tap("#tab_home")
                }.action {
                    tap("#nav_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=none")
                }
            }
            scene(6, "1回目(奇数回目=開く)。ifCanSelect が成立してキャンセルする") {
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
            scene(7, "2回目(偶数回目=開かない)。ifCanSelect が不成立でもそのまま通る") {
                action {
                    tap("#btn_maybe_dialog")
                    ifCanSelect("#btn_dialog_cancel", waitSeconds: 1) {
                        tap("#btn_dialog_cancel")
                    }
                }.expectation {
                    exist("#txt_dialog_result")
                }
            }
            scene(8, "09.S0040: back でダイアログが閉じる") {
                condition {
                    tap("#tab_home")
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
            scene(9, "14.S0020: repeatWhileCanSelect が解決できる限り繰り返す") {
                condition {
                    tap("#tab_home")
                    tap("#nav_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=none")
                }
            }
            scene(10, "出るか不定なダイアログを、出なくなるまで閉じ続ける") {
                action {
                    // #btn_maybe_dialog は奇数回目だけダイアログを開く(ui-contract.md)。
                    // 「開いたら閉じる」を上限まで繰り返す = 件数不定の一括操作の縮図
                    tap("#btn_maybe_dialog")
                }.expectation {
                    // 1回目は必ず開く。ここで肯定側の検証を1つ置いておくと、最後の notExist が
                    // 「id の綴り誤りでも成功する」経路に落ちない(run 終了時の警告と同じ趣旨)
                    exist("#txt_dialog_title")
                }.action {
                    repeatWhileCanSelect("#btn_dialog_cancel", max: 3, title: "ダイアログを閉じる") {
                        tap("#btn_dialog_cancel")
                        tap("#btn_maybe_dialog")
                    }
                }.expectation {
                    // 上限で止まっても失敗にはならない契約。最後は必ず閉じている
                    notExist("#txt_dialog_title")
                }
            }
            scene(11, "21.S0060: waitForClose がダイアログの消滅を待つ") {
                condition {
                    tap("#tab_home")
                }.action {
                    tap("#nav_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=none")
                }
            }
            scene(12, "ダイアログを開いて OK し、waitForClose で閉じるのを待つ") {
                action {
                    tap("#btn_show_dialog")
                }.expectation {
                    exist("#txt_dialog_title")
                }.action {
                    tap("#btn_dialog_ok")
                    waitForClose("#txt_dialog_title", waitSeconds: 5)
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=ok")
                }.action {
                    tap("#tab_home")
                }
            }
        }
    }
}
