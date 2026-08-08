// 10_ライフサイクルとプラットフォーム分岐.swift
// ftester 機能: `restartApp`(terminate+launch でのプロセス内状態リセット・永続カウンタは残る)/
// `terminateApp`(落としたことは次の launchApp の launch カウンタでのみ観測できる)と
// `ios {}` / `android {}` によるプラットフォーム分岐・**ブリッジが要素の状態を供給していること**
// (24.S0010。Slider の value は AccessibilityNodeInfo.getRangeInfo() が唯一の供給源で、
// echo Text は SUT が自前で描くためブリッジが黙っても緑のまま。ここは emission そのものを見る)。
// S0020 の境界は旧シナリオ境界を tap("#tab_home") + 再ナビへ置き換えてある
// (App() はタブ/子画面切替で remember 状態を破棄するため、volume=50 等の初期値はこれだけで戻る)。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class ライフサイクルとプラットフォーム分岐が正しく働くこと {

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

    @Test("プラットフォーム分岐でそれぞれの platform 表記になる・Slider の現在値が value として木に載る")
    func S0020() {
        scenario {
            scene(1, "10.S0020: ライフサイクル画面を開く") {
                condition {
                    launchApp()
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
            scene(3, "24.S0010: Slider の現在値が value として木に載る") {
                condition {
                    tap("#tab_home")
                }.action {
                    tap("#tab_controls")
                    tap("#btn_controls_reset")
                }.expectation {
                    select("#txt_slider").textIs("volume=50")   // 先にアプリ側の状態を確定させる
                }
            }
            scene(4, "ブリッジの供給を echo とは独立に確認する") {
                expectation {
                    android { select("#slider_volume").valueIs("50") }
                    ios { select("#slider_volume").valueIs("50.0") }
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
