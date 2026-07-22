// 10_ライフサイクルとプラットフォーム分岐.swift
// ftester 機能: `relaunchApp`(terminate+launch でのプロセス内状態リセット・永続カウンタは残る)と
// `ios {}` / `android {}` によるプラットフォーム分岐。
// Flutter は1つのコードから両OSのバイナリが出るため、同一シナリオが両OSで回る唯一の新規 SUT。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class ライフサイクルとプラットフォーム分岐が正しく働くこと {

    @Test("relaunchApp でプロセス内カウンタはリセットされ永続カウンタは加算される")
    func S0010() {
        scenario {
            scene(1, "ライフサイクル画面を開き永続カウンタを基準化") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // 既定(true)だと occlusion-guard が FM 視覚照合を呼び、Flutter の小さな
                    // テキスト領域を「覆われている」と誤判定して落ちることがある
                    // (実際には完全に見えている。2026-07-23 実測)。可視性の検証は 01 が行う。
                    exist("#txt_home_marker", requireVisible: false)
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
        }
    }

    @Test("プラットフォーム分岐でそれぞれの platform 表記になる")
    func S0020() {
        scenario {
            scene(1, "ライフサイクル画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // 既定(true)だと occlusion-guard が FM 視覚照合を呼び、Flutter の小さな
                    // テキスト領域を「覆われている」と誤判定して落ちることがある
                    // (実際には完全に見えている。2026-07-23 実測)。可視性の検証は 01 が行う。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_lifecycle")
                }.expectation {
                    exist("#txt_platform")
                }
            }
            scene(2, "ios {} / android {} で platform 表記を確認") {
                expectation {
                    ios { textIs("#txt_platform", "platform=iOS") }
                    android { textIs("#txt_platform", "platform=Android") }
                }
            }
        }
    }

    @Test("コントロール(Switch/Checkbox/ラジオ/Slider)の状態が echo に反映される")
    func S0030() {
        scenario {
            scene(1, "コントロールタブを開いて初期値を確認") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // 既定(true)だと occlusion-guard が FM 視覚照合を呼び、Flutter の小さな
                    // テキスト領域を「覆われている」と誤判定して落ちることがある
                    // (実際には完全に見えている。2026-07-23 実測)。可視性の検証は 01 が行う。
                    exist("#txt_home_marker", requireVisible: false)
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
