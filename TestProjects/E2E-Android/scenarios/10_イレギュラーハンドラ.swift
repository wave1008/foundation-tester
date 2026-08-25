// 10_イレギュラーハンドラ.swift
// fleetest 機能: `irregularHandler`(出るか不定なアプリ内メッセージを宣言すると、以降どのステップでも
// 出た時点で自動的に閉じる)。閉じる操作は各コマンドがロケータを解決する直前に走る
// (StepExecutor.dismissInterruption)ため、検証コマンド(expectation)・操作コマンド(action)の
// どちらが先にダイアログへぶつかっても同じ結果になることを見る。
// 07_条件分岐とダイアログ.swift は handler 未宣言のときの ifCanSelect/select の検証で、
// この自動クローズと混ざらないよう別ファイルにしている。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class イレギュラーハンドラーが不定なダイアログを自動的に閉じること {

    // 宣言の寿命はシナリオ1本。以降どのステップでも #txt_dialog_title が出た時点で
    // #btn_dialog_cancel を自動タップする(閉じ方はアプリ作者しか知らないためツールは推測しない)
    func setUp() {
        irregularHandler("#txt_dialog_title", dismiss: "#btn_dialog_cancel")
    }

    @Test("検証コマンド・操作コマンドのどちらの解決前でも自動的にダイアログを閉じる")
    func S0010() {
        scenario {
            scene(1, "検証コマンド(textIs)の解決前に検出されて自動で閉じる") {
                condition {
                    launchApp()
                    tap("#nav_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=none")
                }.action {
                    tap("#btn_show_dialog")
                }.expectation {
                    // #btn_dialog_cancel を明示的にタップしていない。次の textIs が
                    // ロケータを解決する直前に handler がダイアログを検出して自動タップするため、
                    // echo が "cancel" になり notExist も即成立する
                    select("#txt_dialog_result").textIs("dialog=cancel")
                    notExist("#txt_dialog_title")
                }
            }
            scene(2, "操作コマンド(tap)の解決前に検出されて自動で閉じる") {
                action {
                    tap("#btn_show_dialog")
                    // 直前で開いたダイアログは、この tap がロケータを解決する前に handler が
                    // 自動で閉じる。閉じたことで #btn_maybe_dialog は決定的に「1回目」となり
                    // (奇数回目=開く。ui-contract.md)、タップ後は再びダイアログが開いた状態になる
                    tap("#btn_maybe_dialog")
                }.expectation {
                    // 直後の textIs の解決前に再び handler が発火してこのダイアログも閉じる
                    select("#txt_dialog_result").textIs("dialog=cancel")
                    notExist("#txt_dialog_title")
                }
            }
        }
    }
}
