// 10_ライフサイクルとコントロール.swift
// ftester 機能: `relaunchApp`(terminate+launch でのプロセス内状態リセット・永続カウンタは残る)と、
// **ComposeView 側**のコントロール(Switch / Checkbox / RadioButton / Slider)の状態遷移検証。
// この画面だけ Compose なので、型は View 側と異なる(Switch/Button → `Cell`、
// Checkbox/RadioButton → `CheckBox`)。値検証は型に依存しない echo Text で行う契約。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class ライフサイクルとコントロールが正しく働くこと {

    @Test("relaunchApp でプロセス内カウンタはリセットされ永続カウンタは加算される")
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
            scene(3, "relaunchApp 後: session はリセット・launch は+1・ホームのルートに戻る") {
                action {
                    relaunchApp()
                }.expectation {
                    exist("#txt_home_marker")
                }.action {
                    tap("#nav_lifecycle")
                }.expectation {
                    textIs("#txt_session_count", "session=0")
                    textIs("#txt_launch_count", "launch=2")
                }
            }
            scene(4, "platform 表記は Android") {
                expectation {
                    textIs("#txt_platform", "platform=Android")
                }
            }
        }
    }

    @Test("Compose 側の Switch / Checkbox / RadioButton / Slider の状態が echo に反映される")
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
}
