// 08_ライフサイクルとコントロール.swift
// fleetest 機能: `restartApp`(terminate+launch でのプロセス内状態リセット・永続カウンタは残る)/
// `terminateApp`(落としたことは次の launchApp の launch カウンタでのみ観測できる)と、
// ネイティブ UI コントロール(Switch / Slider / トグルボタン)の状態遷移・`enabledIsFalse`/
// `enabledIsTrue`(11)の検証。
// Compose 版 10 の `ios {}` / `android {}` 分岐に相当する部分は、この SUT が iOS 専用のため
// platform: "ios" 固定で置き換えている。
// S0020 は旧シナリオ境界を tap("#tab_home") + 再ナビへ置き換えて11の検証を統合してある
// (AppShell はタブ切替で子画面の @State を破棄するため、agree=false 等の初期値はこれだけで戻る)。

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
            scene(4, "platform 表記は iOS") {
                expectation {
                    select("#txt_platform").textIs("platform=iOS")
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

    @Test("Switch / チェック / ラジオ / Slider の状態が echo に反映される・enabled 状態の判定")
    func S0020() {
        scenario {
            scene(1, "10.S0020: Switch / チェック / ラジオ / Slider の状態が echo に反映される") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_controls")
                }.expectation {
                    select("#txt_sw_notify").textIs("notify=off")
                    select("#txt_cb_agree").textIs("agree=false")
                    select("#txt_radio").textIs("plan=A")
                    select("#txt_slider").textIs("volume=50")
                    // **ブリッジが Slider の value を供給していること**(echo Text とは別の検証)。
                    // "50%" は XCUIElement.value のパーセント表記(ui-contract.md)。
                    // これが無いと、ランナーが value を落とす退行を E2E が一生検出できない
                    // (echo は SUT が自前で描くので、ブリッジが黙っても緑のまま)
                    select("#slider_volume").valueIs("50%")
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
                    tapWithScrollDown("#btn_controls_reset")
                    scrollToTop()
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
                    tapWithScrollDown("#btn_controls_reset")
                    scrollToTop()
                }.expectation {
                    select("#btn_always_disabled").enabledIsFalse()
                    select("#btn_toggle_target").enabledIsFalse()
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
