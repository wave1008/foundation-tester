// 10_イレギュラーハンドラ.swift
// fleetest 機能: `irregularHandler`(出るか不定なアプリ内メッセージの検出・自動終了)。
// 07_条件分岐とダイアログ.swift はハンドラなしでのダイアログ操作(ifCanSelect/select)を検証しており、
// 干渉させないためこちらは分けて irregularHandler 専用に検証する。
// CMP 版(TestProjects/E2E-CMP/scenarios/17_イレギュラーハンドラ.swift)の移植。Flutter の AlertDialog は
// 通常の Semantics として出るため、E2E-iOS 版のようなラベルへのフォールバックは不要
// (#txt_dialog_title がそのまま引ける。E2EAppFlutter/docs/ui-contract.md)。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
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
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の fleetest 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=none")
                }.action {
                    tap("#btn_show_dialog")
                }.expectation {
                    // textIs/notExist はどちらも判定前にスナップショットを取る。そこで
                    // #txt_dialog_title を検出し #btn_dialog_cancel を自動タップしてから判定する
                    // (検証コマンドでも発火する仕様の固定。閉じたことはステップの注記に残る)
                    select("#txt_dialog_result").textIs("dialog=cancel")
                    notExist("#txt_dialog_title")
                }
            }
            scene(2, "操作コマンド側の発火: 次のタップの解決前に自動で閉じられる") {
                action {
                    tap("#btn_show_dialog")
                    // 直前で開いたダイアログはこのタップの解決前に自動で閉じられ、続けて
                    // 交互ダイアログ(#btn_maybe_dialog)の1回目タップ(奇数回目=開く)で再び開く
                    tap("#btn_maybe_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=cancel")
                    notExist("#txt_dialog_title")
                }
            }
        }
    }

    // 抑止の命令形(`disableHandler()` / `enableHandler()`)。**CAE のブロックを跨げるのはこの形だけ**
    // (ブロック形は1つの CAE ブロックの内側にしか置けない)。止まっていなければ action の
    // tap("#btn_dialog_ok") の解決前にキャンセルで閉じられ、OK が見つからずに落ちる
    @Test("disableHandler はブロックを跨いで自動クローズを止め、enableHandler で戻る")
    func S0020() {
        scenario {
            scene(1, "disableHandler の後はブロックを跨いでもダイアログが残り、自分で OK を押せる") {
                condition {
                    launchApp()
                    // 起動直後のポインタ入力の取りこぼし対策の1往復(S0010 scene 1 と同じ理由)
                    exist("#txt_home_marker", requireVisible: false)
                    tap("#nav_dialog")
                    disableHandler()
                    tap("#btn_show_dialog")
                }.action {
                    tap("#btn_dialog_ok")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=ok")
                    enableHandler()
                }
            }
            scene(2, "enableHandler の後は自動クローズが戻る") {
                action {
                    tap("#btn_show_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=cancel")
                    notExist("#txt_dialog_title")
                }
            }
        }
    }

    // ブロック形の抑止(`suppressHandler { }`)と、その内側だけ自動クローズを戻す `useHandler { }`。
    // 3つの向きを1本で分ける: 抑止中は閉じない(exist が通る)/ useHandler の中は閉じる(cancel)/
    // useHandler を出たら抑止に戻る(OK を自分で押せる)
    @Test("suppressHandler の中では閉じず、入れ子の useHandler の中だけ閉じる")
    func S0030() {
        scenario {
            scene(1, "抑止中に開いたダイアログを useHandler が閉じ、出た後は再び抑止される") {
                condition {
                    launchApp()
                    // 起動直後のポインタ入力の取りこぼし対策の1往復(S0010 scene 1 と同じ理由)
                    exist("#txt_home_marker", requireVisible: false)
                    tap("#nav_dialog")
                }.action {
                    suppressHandler {
                        tap("#btn_show_dialog")
                        // 抑止していなければこの検証の前に閉じられて落ちる
                        exist("#txt_dialog_title")
                        useHandler {
                            // 内側だけ自動クローズが戻る: 照合の前にキャンセルで閉じられる
                            select("#txt_dialog_result").textIs("dialog=cancel")
                        }
                        tap("#btn_show_dialog")
                        // 抑止に戻っていなければこの tap の解決前に閉じられ、OK が見つからずに落ちる
                        tap("#btn_dialog_ok")
                    }
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=ok")
                }
            }
        }
    }
}
