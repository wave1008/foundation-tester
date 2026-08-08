// 09_条件分岐とダイアログ.swift
// ftester 機能: `ifCanSelect`(出るか不定な要素への条件分岐)と `select`(掴めなければ空要素を返す)。
// #btn_maybe_dialog は奇数回目だけダイアログを開く決定的仕様のため、ifCanSelect の
// 「出ても出なくても通る」ことの検証材料になる。
// **`select` の空振り検証は S0010 の最終シーンへ統合した**(2026-08-04)。導入シーンが同一で、
// launchApp + ナビの固定費だけが増えていたため(全 E2E スイートは合計律速 =
// docs/performance-tuning.md §3.6)。**交互ダイアログ(S0020)は分離を維持する** ——
// #btn_maybe_dialog のカウンタは画面離脱でリセットされる仕様で、他の検証と同居させると
// 「何回目のタップか」がシーンの並びに依存するため。
// **予測**: SUT のダイアログは RN の `Modal`(transparent)+ 通常の View/Text 群
// (E2EAppRN/src/ui.tsx DialogOverlay)。ネイティブのアラートウィンドウ(UIAlertController/
// AlertDialog の既定ボタン)ではなく、見出し・ボタンとも testID をそのまま持つ通常の要素なので、
// #txt_dialog_title が両 OS で引けると予測している(iOS ネイティブ SUT の UIAlertController では
// 引けない。ここが差になるはず。未検証)。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class 条件分岐とダイアログ操作が正しく働くこと {

    @Test("ダイアログの OK/キャンセルで結果が反映される")
    func S0010() {
        scenario {
            scene(1, "ダイアログ画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // 起動直後は a11y ツリー完成後もポインタ入力を一時的に取りこぼす実装が
                    // Flutter で実測されている。RN で同じ罠があるかは未検証だが、害の無い
                    // 1往復なので安全側として残す。
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
        }
    }

    @Test("ifCanSelect は出ても出なくても通る(交互ダイアログ)")
    func S0020() {
        scenario {
            scene(1, "ダイアログ画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // 起動直後は a11y ツリー完成後もポインタ入力を一時的に取りこぼす実装が
                    // Flutter で実測されている。RN で同じ罠があるかは未検証だが、害の無い
                    // 1往復なので安全側として残す。
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

    @Test("back でダイアログが閉じる(Android のみ)")
    func S0040() {
        scenario {
            // すべて android {} で包む: iOS のエッジスワイプ back は本 SUT(独自ナビ。React Navigation 等の
            // ライブラリを使わない自前の状態遷移)では観測不能(docs/commands.md の back() 契約)。
            // iOS 側でダイアログを開いたまま残すと後続シナリオを壊すため、iOS では何も実行しない
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
