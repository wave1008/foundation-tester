// 10_イレギュラーハンドラ.swift
// fleetest 機能: `irregularHandler`(出るか不定のアプリ内メッセージを、操作/検証どちらの
// 待機中でも自動的に閉じる割り込みハンドラ)。
// 07_条件分岐とダイアログ.swift はハンドラ**無し**でのダイアログ手動操作(ifCanSelect/select)を
// 検証しているため、干渉しないよう別クラス・別ファイルにした。
// **この SUT 固有の罠**: ダイアログ見出し(CMP 版の `#txt_dialog_title`)は
// accessibilityIdentifier が届かず存在しない(E2EAppIOS/docs/ui-contract.md)。
// 検出セレクタはラベル「確認」を使う(09 と同じ回避)。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class イレギュラーハンドラでダイアログが自動的に閉じられること {

    func setUp() {
        // 宣言の寿命はシナリオ1本。setUp に置けば各 @Test の前に自動で入る
        irregularHandler("確認", dismiss: "#btn_dialog_cancel")
    }

    @Test("検証コマンド・操作コマンドいずれの待機中でも割り込みハンドラが発火する")
    func S0010() {
        scenario {
            scene(1, "検証コマンドの待機中に割り込みハンドラが発火してダイアログを閉じる") {
                condition {
                    launchApp()
                    tap("#nav_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=none")
                }.action {
                    tap("#btn_show_dialog")
                }.expectation {
                    // ダイアログは開いたままここへ来るが、textIs はポーリングの各周回で
                    // dismissInterruption を評価するため、待機中に「確認」を検出して
                    // #btn_dialog_cancel を自動タップする(検証コマンドでも発火する仕様。
                    // アクション限定だと exist/textIs の待機中に出た分を閉じられない。design.md)
                    select("#txt_dialog_result").textIs("dialog=cancel")
                    notExist("確認")
                }
            }
            scene(2, "操作コマンド側でも、次の操作の前に割り込みハンドラが発火する") {
                action {
                    tap("#btn_show_dialog")
                    // 直前で開いたダイアログは、この tap の実行前スナップショットで検出され
                    // 自動的に閉じられる。閉じたあと #btn_maybe_dialog の1回目タップ
                    // (奇数回目=開く。ui-contract.md)で再びダイアログが開く
                    tap("#btn_maybe_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=cancel")
                    notExist("確認")
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
                    notExist("確認")
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
                    tap("#nav_dialog")
                }.action {
                    suppressHandler {
                        tap("#btn_show_dialog")
                        // 抑止していなければこの検証の前に閉じられて落ちる
                        exist("確認")
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
