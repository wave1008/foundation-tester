// 10_ライフサイクルとコントロール.swift
// ftester 機能: `restartApp`(terminate+launch でのプロセス内状態リセット・永続カウンタは残る)/
// `terminateApp`(落としたことは次の launchApp の launch カウンタでのみ観測できる)と、
// ネイティブ UI コントロール(Switch / Slider / トグルボタン)の状態遷移検証。
// Compose 版 10 の `ios {}` / `android {}` 分岐に相当する部分は、この SUT が iOS 専用のため
// platform: "ios" 固定で置き換えている。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class ライフサイクルとコントロールが正しく働くこと {

    @Test("restartApp / terminateApp でプロセス内カウンタと永続カウンタが期待どおり動く")
    func S0010() {
        scenario {
            scene(1, "ライフサイクル画面を開き永続カウンタを基準化") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_lifecycle")
                    tap("#btn_reset_persisted")
                }.expectation {
                    textIs("#txt_launch_count", "launch=1")
                }
            }
            scene(2, "セッションカウンタを2回加算") {
                action {
                    tap("#btn_session_inc")
                    tap("#btn_session_inc")
                }.expectation {
                    textIs("#txt_session_count", "session=2")
                }
            }
            scene(3, "restartApp 後: session はリセット・launch は+1・ホームのルートに戻る") {
                action {
                    restartApp()
                }.expectation {
                    exist("#txt_home_marker")
                }.action {
                    tap("#nav_lifecycle")
                }.expectation {
                    textIs("#txt_session_count", "session=0")
                    textIs("#txt_launch_count", "launch=2")
                }
            }
            scene(4, "platform 表記は iOS") {
                expectation {
                    textIs("#txt_platform", "platform=iOS")
                }
            }
            // `terminateApp` は restartApp の半分だけを撃つ。**落ちたことは次の launchApp の
            // launch カウンタでしか観測できない**(落ちていなければ +1 されない)
            scene(5, "terminateApp でプロセスが落ち、次の launchApp で launch が +1 される") {
                action {
                    terminateApp()
                    launchApp()
                    tap("#nav_lifecycle")
                }.expectation {
                    textIs("#txt_launch_count", "launch=3")
                    textIs("#txt_session_count", "session=0")
                }
            }
        }
    }

    @Test("Switch / チェック / ラジオ / Slider の状態が echo に反映される")
    func S0020() {
        scenario {
            scene(1, "コントロールタブを開いて初期値を確認") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_controls")
                }.expectation {
                    textIs("#txt_sw_notify", "notify=off")
                    textIs("#txt_cb_agree", "agree=false")
                    textIs("#txt_radio", "plan=A")
                    textIs("#txt_slider", "volume=50")
                }
            }
            scene(2, "Switch とチェックを ON にする") {
                action {
                    tap("#sw_notify")
                    tap("#cb_agree")
                }.expectation {
                    textIs("#txt_sw_notify", "notify=on")
                    textIs("#txt_cb_agree", "agree=true")
                }
            }
            scene(3, "ラジオを B へ切り替える") {
                action {
                    tap("#radio_b")
                }.expectation {
                    textIs("#txt_radio", "plan=B")
                }
            }
            scene(4, "リセットで全て初期値に戻る") {
                action {
                    tap("#btn_controls_reset")
                }.expectation {
                    textIs("#txt_sw_notify", "notify=off")
                    textIs("#txt_cb_agree", "agree=false")
                    textIs("#txt_radio", "plan=A")
                    textIs("#txt_slider", "volume=50")
                }
            }
        }
    }

    @Test("clearAppData でアプリのデータが消える")
    func S0030() {
        scenario {
            // clearAppData はアプリを残しデータだけ消す(iOS はシミュレータ専用)
            scene(1, "入力して echo に値が残る") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_input")
                    tap("#field_single")
                    type("#field_single", "persist99")
                    tap("#btn_input_submit")
                }.expectation {
                    textIs("#txt_input_submitted", "submitted=persist99")
                }
            }
            scene(2, "clearAppData 後に起動すると初期状態に戻る") {
                action {
                    clearAppData()
                    launchApp()
                    tap("#nav_input")
                }.expectation {
                    textIs("#txt_input_submitted", "submitted=-")
                    textIs("#txt_echo_single", "single=")
                }
            }
        }
    }
}
