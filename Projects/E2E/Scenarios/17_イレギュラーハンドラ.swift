// 17_イレギュラーハンドラ.swift
// ftester 機能: `irregularHandler`(出るか不定なアプリ内メッセージの検出・自動終了)。
// 09_条件分岐とダイアログ.swift はハンドラなしでのダイアログ操作(ifCanSelect/optional)を検証しており、
// 干渉させないためこちらは分けて irregularHandler 専用に検証する。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class イレギュラーハンドラが自動でダイアログを閉じること {

    // 宣言の寿命はシナリオ1本なので setUp に置くのが定石(docs/commands.md)
    func setUp() {
        irregularHandler("#txt_dialog_title", dismiss: "#btn_dialog_cancel")
    }

    @Test("宣言後は検証コマンド・操作コマンドどちらの発火でもダイアログが自動的に閉じる")
    func S0010() {
        scenario {
            scene(1, "検証コマンド側の発火: expectation の照合前に自動で閉じられる") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_dialog")
                }.expectation {
                    textIs("#txt_dialog_result", "dialog=none")
                }.action {
                    tap("#btn_show_dialog")
                }.expectation {
                    // textIs/notExist はどちらも判定前にスナップショットを取る。そこで
                    // #txt_dialog_title を検出し #btn_dialog_cancel を自動タップしてから判定する
                    // (検証コマンドでも発火する仕様の固定。閉じたことはステップの注記に残る)
                    textIs("#txt_dialog_result", "dialog=cancel")
                    notExist("#txt_dialog_title")
                }
            }
            scene(2, "操作コマンド側の発火: 次のタップの解決前に自動で閉じられる") {
                action {
                    tap("#btn_show_dialog")
                    // 直前で開いたダイアログはこのタップの解決前に自動で閉じられ、
                    // 続けて交互ダイアログ(#btn_maybe_dialog)の1回目タップ(奇数回目=開く)で再び開く
                    tap("#btn_maybe_dialog")
                }.expectation {
                    textIs("#txt_dialog_result", "dialog=cancel")
                    notExist("#txt_dialog_title")
                }
            }
        }
    }
}
