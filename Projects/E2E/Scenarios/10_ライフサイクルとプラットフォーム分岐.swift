// 10_ライフサイクルとプラットフォーム分岐.swift
// ftester 機能: `relaunchApp`(terminate+launch でのプロセス内状態リセット・永続カウンタは残る)と
// `ios {}` / `android {}` によるプラットフォーム分岐。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class ライフサイクルとプラットフォーム分岐が正しく働くこと {

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
        }
    }

    @Test("プラットフォーム分岐でそれぞれの platform 表記になる")
    func S0020() {
        scenario {
            scene(1, "ライフサイクル画面を開く") {
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
                    ios { textIs("#txt_platform", "platform=iOS") }
                    android { textIs("#txt_platform", "platform=Android") }
                }
            }
        }
    }
}
