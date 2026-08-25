// 08_ライフサイクルとプラットフォーム分岐.swift
// fleetest 機能: `restartApp`(terminate+launch でのプロセス内状態リセット・永続カウンタは残る)/
// `terminateApp`(落としたことは次の launchApp の launch カウンタでのみ観測できる)/
// `ios {}` / `android {}` によるプラットフォーム分岐 / コントロール(Switch/Checkbox/ラジオ/Slider)の
// 状態遷移 / `enabledIsFalse`/`enabledIsTrue`(旧 11_操作可否アサーション)/ `clearAppData` をまとめて
// 検証する。Flutter は1つのコードから両OSのバイナリが出るため、同一シナリオが両OSで回る唯一の新規 SUT。
// **この SUT に置く 11 の意味**: enabled の表現はフレームワークごとに実装が違う
// (Flutter は onPressed: null)ため、a11y ツリーに出る enabled 属性が
// AppDriver から上で同じに見えることをフレームワーク別に確かめる。
// **S0020 は旧シナリオ境界を tap("#tab_home") + 再ナビへ置き換えて11の検証を統合してある**
// (AppShell はタブ切替で子画面の State を破棄するため、agree=false 等の初期値はこれだけで戻る)。
// **S0010(ライフサイクル)と S0040(clearAppData)は無変更**(それぞれ他クラスタと同居させると
// restartApp/terminateApp・データ消去の副作用が別の検証と干渉するため、独立のまま残す)。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class ライフサイクルとプラットフォーム分岐が正しく働くこと {

    @Test("restartApp / terminateApp でプロセス内カウンタと永続カウンタが期待どおり動く")
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
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の fleetest 欠陥」参照。ここで guard を切っても検出器は死なない)。
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

    @Test("プラットフォーム分岐でそれぞれの platform 表記になる・コントロールの状態遷移・enabled 状態の判定")
    func S0020() {
        scenario {
            scene(1, "10.S0020: プラットフォーム分岐でそれぞれの platform 表記になる") {
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
            scene(3, "10.S0030: コントロール(Switch/Checkbox/ラジオ/Slider)の状態が echo に反映される") {
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
                    tap("#nav_input")
                    // Android は input connection が張られるまで ACTION_SET_TEXT を受け付けない
                    // (500「ACTION_SET_TEXT を受け付けないフィールドです」で落ちる)。Flutter は
                    // この接続確立が tap 応答より遅れるため、tap と type の間に1往復挟んで待つ。
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
