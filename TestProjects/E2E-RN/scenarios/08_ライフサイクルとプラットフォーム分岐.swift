// 08_ライフサイクルとプラットフォーム分岐.swift
// ftester 機能: `restartApp`(terminate+launch でのプロセス内状態リセット・永続カウンタは残る)/
// `terminateApp`(落としたことは次の launchApp の launch カウンタでのみ観測できる)と
// `ios {}` / `android {}` によるプラットフォーム分岐・ネイティブ UI コントロール
// (Switch / Slider / チェック / ラジオ)の状態遷移・`enabledIsFalse`/`enabledIsTrue`(旧11)の検証。
// RN も1つのコードから両OSのバイナリが出るため、Flutter と並び同一シナリオが両OSで回る新規 SUT。
// S0020 は旧シナリオ境界を tap("#tab_home") + 再ナビへ置き換えて旧 10.S0030(コントロール)と
// 旧 11_操作可否アサーション.S0010(enabled 判定)を統合してある(2026-08-08。旧 10.S0020 + S0030 +
// 11.S0010)。AppShell はタブ切替で homeChild を null に戻し(タブ切替そのものも ControlsScreen を
// アンマウントする)、agree=false 等の初期値はこれだけで戻る。**S0010(restartApp/terminateApp)と
// S0040(clearAppData)は他クラスタと舞台が異なるため無変更**。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class ライフサイクルとプラットフォーム分岐が正しく働くこと {

    @Test("restartApp / terminateApp でプロセス内カウンタと永続カウンタが期待どおり動く")
    func S0010() {
        scenario {
            scene(1, "ライフサイクル画面を開き永続カウンタを基準化") {
                condition {
                    launchApp()
                }.expectation {
                    // 起動直後は a11y ツリー完成後もポインタ入力を一時的に取りこぼす実装が
                    // Flutter で実測されている。RN で同じ罠があるかは未検証だが、害の無い
                    // 1往復なので安全側として残す。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
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
            // `terminateApp` は restartApp の半分だけを撃つ。**落ちたことは次の launchApp の
            // launch カウンタでしか観測できない**(落ちていなければ +1 されない)
            scene(4, "terminateApp でプロセスが落ち、次の launchApp で launch が +1 される") {
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

    @Test("プラットフォーム分岐でそれぞれの platform 表記になる・コントロールの状態が echo に反映される・enabled 状態の判定")
    func S0020() {
        scenario {
            scene(1, "10.S0020: プラットフォーム分岐でそれぞれの platform 表記になる") {
                condition {
                    launchApp()
                }.expectation {
                    // 起動直後は a11y ツリー完成後もポインタ入力を一時的に取りこぼす実装が
                    // Flutter で実測されている。RN で同じ罠があるかは未検証だが、害の無い
                    // 1往復なので安全側として残す。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_lifecycle")
                }.expectation {
                    exist("#txt_platform")
                }
            }
            scene(2, "ios {} / android {} で platform 表記を確認") {
                expectation {
                    ios { select("#txt_platform").textIs("platform=iOS") }
                    android { select("#txt_platform").textIs("platform=Android") }
                }
            }
            scene(3, "10.S0030: コントロールタブを開いて初期値を確認") {
                condition {
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#tab_controls")
                }.expectation {
                    select("#txt_sw_notify").textIs("notify=off")
                    select("#txt_cb_agree").textIs("agree=false")
                    select("#txt_radio").textIs("plan=A")
                    select("#txt_slider").textIs("volume=50")
                }
            }
            scene(4, "Switch とチェックを ON にする") {
                action {
                    tap("#sw_notify")
                    tap("#cb_agree")
                }.expectation {
                    select("#txt_sw_notify").textIs("notify=on")
                    select("#txt_cb_agree").textIs("agree=true")
                }
            }
            scene(5, "ラジオを B へ切り替える") {
                action {
                    tap("#radio_b")
                }.expectation {
                    select("#txt_radio").textIs("plan=B")
                }
            }
            scene(6, "リセットで全て初期値に戻る") {
                action {
                    tap("#btn_controls_reset")
                }.expectation {
                    select("#txt_sw_notify").textIs("notify=off")
                    select("#txt_cb_agree").textIs("agree=false")
                    select("#txt_radio").textIs("plan=A")
                    select("#txt_slider").textIs("volume=50")
                }
            }
            scene(7, "11.S0010: 常時無効ボタンと条件付きボタンの enabled 状態を判定する") {
                condition {
                    tap("#tab_home")
                    tap("#tab_controls")
                    tap("#btn_controls_reset")
                }.expectation {
                    select("#btn_always_disabled").enabledIsFalse()
                    select("#btn_toggle_target").enabledIsFalse()
                }
            }
            scene(8, "同意すると条件付きボタンだけが有効になる") {
                action {
                    tap("#cb_agree")
                }.expectation {
                    select("#txt_cb_agree").textIs("agree=true")
                    select("#btn_toggle_target").enabledIsTrue()
                    // 常時無効ボタンは影響を受けない
                    select("#btn_always_disabled").enabledIsFalse()
                }
            }
            scene(9, "同意を外すと条件付きボタンは無効に戻る") {
                action {
                    // group は記録に [名前] を前置するだけのまとまり(実行・失敗の扱いは素の列と同じ)
                    group("同意を外す") {
                        select("#cb_agree").enabledIsTrue()
                        tap("#cb_agree")
                    }
                }.expectation {
                    select("#txt_cb_agree").textIs("agree=false")
                    select("#btn_toggle_target").enabledIsFalse()
                }.action {
                    tap("#tab_home")
                }
            }
        }
    }

    @Test("clearAppData でアプリのデータが消える")
    func S0040() {
        scenario {
            // clearAppData はアプリを残しデータだけ消す(iOS はシミュレータ専用)
            scene(1, "入力して echo に値が残る") {
                condition {
                    launchApp()
                }.expectation {
                    // 起動直後は a11y ツリー完成後もポインタ入力を一時的に取りこぼす実装が
                    // Flutter で実測されている。RN で同じ罠があるかは未検証だが、害の無い
                    // 1往復なので安全側として残す。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_input")
                    // Android は input connection が張られるまで ACTION_SET_TEXT を受け付けない
                    // (500「ACTION_SET_TEXT を受け付けないフィールドです」で落ちる)。tap 直後は
                    // 接続確立前のことがあるため、tap と type の間に1往復挟んで待つ
                    // (Flutter で実測した罠。RN でも安全側として残す)。
                    tap("#field_single")
                }.expectation {
                    exist("#field_single")
                }.action {
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
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_input")
                }.expectation {
                    select("#txt_input_submitted").textIs("submitted=-")
                    select("#txt_echo_single").textIs("single=")
                }
            }
        }
    }
}
