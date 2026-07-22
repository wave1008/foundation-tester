// 10_ライフサイクルとコントロール.swift
// ftester 機能: `relaunchApp`(terminate+launch でのプロセス内状態リセット・永続カウンタは残る)と、
// ネイティブ UI コントロール(Switch / Slider / トグルボタン)の状態遷移検証。
// Compose 版 10 の `ios {}` / `android {}` 分岐に相当する部分は、この SUT が iOS 専用のため
// platform: "ios" 固定で置き換えている。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
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
            scene(4, "platform 表記は iOS") {
                expectation {
                    textIs("#txt_platform", "platform=iOS")
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
}
