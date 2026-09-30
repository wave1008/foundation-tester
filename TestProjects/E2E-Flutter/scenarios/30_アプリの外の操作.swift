// 30_アプリの外の操作.swift
// fleetest 機能: アプリの外を触るコマンド `home` / `appSwitcher` / `tapAppIcon` / `removeApp` / `installApp`。
// 行き先はどれもアプリの外(ホーム画面・アプリスイッチャー・OS のインストーラ)なので、結果はライフサイクル画面の
// カウンタで観測する:
// - session(プロセス内メモリ)が残る = 同じプロセスが前面へ戻った(起動し直していない)
// - launch(永続)が 1 に戻る = 消して入れ直した(上書きの install はデータを残すので、removeApp が効かないと戻らない)
// tapAppIcon の名前はアプリプロファイルの appName(アイコンの下の表示名と完全一致で探す)。
// **S0030 はデバイスから SUT を一度消す**: installApp が落ちるとそのデバイスの後続のシナリオが起動できない。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class アプリの外へ出ても戻ってこられること {

    @Test("home で背面へ送り、tapAppIcon でそのプロセスのまま前面へ戻せる")
    func S0010() {
        scenario {
            scene(1, "セッションカウンタを上げておく") {
                condition {
                    launchApp()
                    exist("#txt_home_marker", requireVisible: false)
                    tap("#nav_lifecycle")
                }.action {
                    tap("#btn_session_inc")
                }.expectation {
                    select("#txt_session_count").textIs("session=1")
                }
            }
            scene(2, "home でホーム画面へ出て、tapAppIcon で戻るとカウンタが残っている") {
                action {
                    home()
                    tapAppIcon()
                }.expectation {
                    select("#txt_session_count").textIs("session=1")
                }
            }
        }
    }

    @Test("appSwitcher を開いても、tapAppIcon でそのプロセスのまま前面へ戻せる")
    func S0020() {
        scenario {
            scene(1, "セッションカウンタを上げておく") {
                condition {
                    launchApp()
                    exist("#txt_home_marker", requireVisible: false)
                    tap("#nav_lifecycle")
                }.action {
                    tap("#btn_session_inc")
                }.expectation {
                    select("#txt_session_count").textIs("session=1")
                }
            }
            scene(2, "appSwitcher を開いてから tapAppIcon で戻るとカウンタが残っている") {
                action {
                    appSwitcher()
                    tapAppIcon()
                }.expectation {
                    select("#txt_session_count").textIs("session=1")
                }
            }
        }
    }

    @Test("removeApp で消して installApp で入れ直すと、永続の値が初期値に戻る")
    func S0030() {
        scenario {
            scene(1, "起動し直して永続カウンタを 2 以上にする") {
                condition {
                    launchApp()
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    restartApp()
                    exist("#txt_home_marker", requireVisible: false)
                    tap("#nav_lifecycle")
                }.expectation {
                    select("#txt_launch_count").textIsNot("launch=1")
                }
            }
            scene(2, "消して入れ直すと launch=1 に戻る") {
                action {
                    removeApp()
                    installApp()
                    launchApp()
                    exist("#txt_home_marker", requireVisible: false)
                    tap("#nav_lifecycle")
                }.expectation {
                    select("#txt_launch_count").textIs("launch=1")
                }
            }
        }
    }
}
