// 07_条件分岐とダイアログ.swift
// ftester 機能: `ifCanSelect`(出るか不定な要素への条件分岐)・`select`(掴めなければ空要素を返す)・
// `back`(Android のみ)・`repeatWhileCanSelect`・`waitForClose` をまとめて検証する
// (旧: 09_条件分岐とダイアログ の S0010・S0020・S0040 / 14 の S0020 / 21 の S0060)。
// #btn_maybe_dialog は奇数回目だけダイアログを開く決定的仕様。**カウンタは画面離脱(タブ再入)で
// 0 に戻る**(AppShell はタブ切替で子画面の State を破棄するため。E2EAppFlutter/docs/ui-contract.md)。
// この統合クラスタは旧シナリオ境界を tap("#tab_home") + 再ナビへ置き換えているため、
// 各ブロックの1回目のタップは常に奇数回目(=開く)として振る舞う。
// **09.S0020(ifCanSelect の交互ダイアログ)はクラスタ内で最初に #btn_maybe_dialog へ触れる位置に
// 置く**(S0010 の直後。パリティ依存の検証材料が後続の 14.S0020 の残り値と混ざらないようにする)。
// SUT のダイアログは Flutter の `AlertDialog`(Navigator のオーバーレイ)。ネイティブのダイアログ
// ウィンドウではないため、見出しもボタンも通常の Semantics として出る
// = `#txt_dialog_title` が両 OS で引ける(iOS ネイティブ SUT では引けない。ここが SUT 間の差)。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class 条件分岐とダイアログ操作が正しく働くこと {

    @Test("ダイアログの OK/キャンセルで結果が反映される・ifCanSelect の交互ダイアログ・back・repeatWhileCanSelect・waitForClose")
    func S0010() {
        scenario {
            scene(1, "09.S0010: ダイアログの OK/キャンセルで結果が反映される") {
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
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
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
            // すべて android {} で包む: iOS のエッジスワイプ back は本 SUT(独自ナビ)では観測不能
            // (docs/commands.md の back() 契約)。iOS 側でダイアログを開いたまま残すと後続シナリオを
            // 壊すため、iOS では何も実行しない
            scene(8, "09.S0040: back でダイアログが閉じる(Android のみ)") {
                condition {
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
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
            scene(9, "14.S0020: repeatWhileCanSelect が解決できる限り繰り返す") {
                condition {
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
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
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
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
