// 08_ライフサイクルとコントロール.swift
// ftester 機能: `restartApp`(terminate+launch でのプロセス内状態リセット・永続カウンタは残る)/
// `terminateApp`(落としたことは次の launchApp の launch カウンタでのみ観測できる)/ `clearAppData`、
// **ComposeView 側**のコントロール(Switch / Checkbox / RadioButton / Slider)の状態遷移・
// `enabledIsFalse`/`enabledIsTrue`・`checkIsON`/`checkIsOFF`・ブリッジの value 供給(SeekBar の
// RangeInfo)をまとめて検証する。
// この画面だけ Compose なので、型は View 側と異なる(Switch/Button → `Cell`、
// Checkbox/RadioButton → `CheckBox`)。値検証は型に依存しない echo Text で行う契約。
// **タブ切替は Compose の `remember` 状態を毎回破棄する**(switchTab が対象が同じでも
// render() で ComposeView を作り直すため。MainActivity.kt 参照)。旧シナリオ境界(S0020 内。
// 旧 11/24 を統合)は tap("#tab_home") でホームへ戻ってから #tab_controls + #btn_controls_reset を
// 叩き直す形に置き換えてある。S0010/S0030 は無変更。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
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
                    select("#txt_launch_count").textIs("launch=1")
                }
            }
            scene(2, "セッションカウンタを2回加算") {
                action {
                    tap("#btn_session_inc")
                    tap("#btn_session_inc")
                }.expectation {
                    select("#txt_session_count").textIs("session=2")
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
                    select("#txt_session_count").textIs("session=0")
                    select("#txt_launch_count").textIs("launch=2")
                }
            }
            scene(4, "platform 表記は Android") {
                expectation {
                    select("#txt_platform").textIs("platform=Android")
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
                    select("#txt_launch_count").textIs("launch=3")
                    select("#txt_session_count").textIs("session=0")
                }
            }
        }
    }

    @Test("Compose 側の Switch/Checkbox/RadioButton/Slider の状態遷移・enabled/checkIsON/checkIsOFF・ブリッジの value 供給")
    func S0020() {
        scenario {
            scene(1, "10.S0020: コントロールタブを開いて初期値を確認") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_controls")
                }.expectation {
                    select("#txt_sw_notify").textIs("notify=off")
                    select("#txt_cb_agree").textIs("agree=false")
                    select("#txt_radio").textIs("plan=A")
                    select("#txt_slider").textIs("volume=50")
                }
            }
            scene(2, "Switch とチェックを ON にする") {
                action {
                    tap("#sw_notify")
                    tap("#cb_agree")
                }.expectation {
                    select("#txt_sw_notify").textIs("notify=on")
                    select("#txt_cb_agree").textIs("agree=true")
                }
            }
            scene(3, "ラジオを B へ切り替える") {
                action {
                    tap("#radio_b")
                }.expectation {
                    select("#txt_radio").textIs("plan=B")
                }
            }
            scene(4, "リセットで全て初期値に戻る") {
                action {
                    tap("#btn_controls_reset")
                }.expectation {
                    select("#txt_sw_notify").textIs("notify=off")
                    select("#txt_cb_agree").textIs("agree=false")
                    select("#txt_radio").textIs("plan=A")
                    select("#txt_slider").textIs("volume=50")
                }
            }
            scene(5, "11.S0010: 常時無効ボタンと条件付きボタンの enabled 状態を判定する") {
                condition {
                    tap("#tab_home")
                    tap("#tab_controls")
                    tap("#btn_controls_reset")
                }.expectation {
                    select("#btn_always_disabled").enabledIsFalse()
                    select("#btn_toggle_target").enabledIsFalse()
                }
            }
            // **出た直後はまだ触れないボタン**(`#btn_enables_late` は 1.5 秒後に有効)。
            // 要素は最初から木に居るので `waitForDisplay` では待ち切れない —— `tap` が
            // 操作可能になるまで待つことの witness(2026-08-21。受け手の実アプリで
            // 「読み込み中の入力欄を叩いて空振り」を踏んだ形の再現)。
            // 待たない実装だと無効なまま撃って `late=-` のままになる
            scene(51, "出た直後はまだ無効なボタンでも tap が届く") {
                condition {
                    tap("#tab_home")
                    tap("#tab_controls")
                }.action {
                    tap("#btn_enables_late")
                }.expectation {
                    select("#txt_late_result").textIs("late=tapped")
                }
            }
            scene(6, "同意すると条件付きボタンだけが有効になる") {
                action {
                    tap("#cb_agree")
                }.expectation {
                    select("#txt_cb_agree").textIs("agree=true")
                    select("#btn_toggle_target").enabledIsTrue()
                    // 常時無効ボタンは影響を受けない
                    select("#btn_always_disabled").enabledIsFalse()
                }
            }
            scene(7, "同意を外すと条件付きボタンは無効に戻る") {
                action {
                    // group は記録に [名前] を前置するだけのまとまり(実行・失敗の扱いは素の列と同じ)
                    group("同意を外す") {
                        select("#cb_agree").enabledIsTrue()
                        tap("#cb_agree")
                    }
                }.expectation {
                    select("#txt_cb_agree").textIs("agree=false")
                    select("#btn_toggle_target").enabledIsFalse()
                }
            }
            scene(8, "コントロールリセットで初期化してから #cb_agree の checkIsON/checkIsOFF を検証する") {
                condition {
                    tap("#btn_controls_reset")
                }.expectation {
                    select("#cb_agree").checkIsOFF()
                    select("#txt_cb_agree").textIs("agree=false")
                }.action {
                    tap("#cb_agree")
                }.expectation {
                    select("#cb_agree").checkIsON()
                    select("#txt_cb_agree").textIs("agree=true")
                }
            }
            scene(9, "#sw_notify も同様に checkIsON/checkIsOFF が echo と一致する") {
                condition {
                    tap("#btn_controls_reset")
                }.expectation {
                    select("#sw_notify").checkIsOFF()
                    select("#txt_sw_notify").textIs("notify=off")
                }.action {
                    tap("#sw_notify")
                }.expectation {
                    select("#sw_notify").checkIsON()
                    select("#txt_sw_notify").textIs("notify=on")
                }
            }
            scene(10, "24.S0010: Slider の現在値が value として木に載る(SeekBar の RangeInfo)") {
                condition {
                    tap("#tab_home")
                    tap("#tab_controls")
                    tap("#btn_controls_reset")
                }.expectation {
                    select("#txt_slider").textIs("volume=50")
                }
            }
            scene(11, "ブリッジの供給を echo とは独立に確認する") {
                expectation {
                    select("#slider_volume").valueIs("50")
                }.action {
                    tap("#tab_home")
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
                    select("#txt_input_submitted").textIs("submitted=persist99")
                }
            }
            scene(2, "clearAppData 後に起動すると初期状態に戻る") {
                action {
                    clearAppData()
                    launchApp()
                    tap("#nav_input")
                }.expectation {
                    select("#txt_input_submitted").textIs("submitted=-")
                    select("#txt_echo_single").textIs("single=")
                }
            }
        }
    }
}
