// 06_ジェスチャ.swift
// ftester 機能: `tap` の連打カウント / `tap(holdSeconds:)`(長押し)と通常タップの区別 / `swipe` 4方向。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class ジェスチャが正しく検出されること {

    @Test("タップ連打・長押し・4方向スワイプが区別して検出される")
    func S0010() {
        scenario {
            scene(1, "ジェスチャ画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_gesture")
                }.expectation {
                    textIs("#txt_tap_count", "tap=0")
                }
            }
            scene(2, "タップ3回でカウントが3になる") {
                action {
                    tap("#btn_tap_counter")
                    tap("#btn_tap_counter")
                    tap("#btn_tap_counter")
                }.expectation {
                    textIs("#txt_tap_count", "tap=3")
                    textIs("#txt_last_gesture", "last=tap")
                }
            }
            scene(3, "長押しでカウントが1になる") {
                action {
                    tap("#btn_long_press", holdSeconds: 1.0)
                }.expectation {
                    textIs("#txt_press_count", "press=1")
                    textIs("#txt_last_gesture", "last=longpress")
                }
            }
            scene(4, "通常タップでは長押しカウントが増えない(区別の検証)") {
                action {
                    tap("#btn_long_press")
                }.expectation {
                    textIs("#txt_press_count", "press=1")
                }
            }
            scene(5, "holdSeconds 指定の長押しも検出される(既定 1 秒以外が実際に届いていること)") {
                action {
                    tap("#btn_long_press", holdSeconds: 2.0)
                }.expectation {
                    textIs("#txt_press_count", "press=2")
                    textIs("#txt_last_gesture", "last=longpress")
                }
            }
            scene(6, "上スワイプ") {
                action {
                    swipe(.up)
                }.expectation {
                    textIs("#txt_swipe_dir", "swipe=up")
                }
            }
            scene(7, "下スワイプ") {
                action {
                    swipe(.down)
                }.expectation {
                    textIs("#txt_swipe_dir", "swipe=down")
                }
            }
            scene(8, "左スワイプ") {
                action {
                    swipe(.left)
                }.expectation {
                    textIs("#txt_swipe_dir", "swipe=left")
                }
            }
            scene(9, "右スワイプ") {
                action {
                    swipe(.right)
                }.expectation {
                    textIs("#txt_swipe_dir", "swipe=right")
                }
            }
            scene(10, "リセットで全カウンタが初期値に戻る") {
                action {
                    tap("#btn_gesture_reset")
                }.expectation {
                    textIs("#txt_tap_count", "tap=0")
                    textIs("#txt_press_count", "press=0")
                    textIs("#txt_swipe_dir", "swipe=-")
                    textIs("#txt_last_gesture", "last=-")
                }
            }
        }
    }

    @Test("swipePointToPoint が座標スワイプとして認識される")
    func S0020() {
        scenario {
            scene(1, "座標を直接指定して上スワイプする") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_gesture")
                    // 座標は snapshot の screen 座標系(iOS pt / Android px)。中央列(x=0.5w 付近)は
                    // ui-contract のジェスチャ画面レイアウト制約により操作要素が置かれず空いている
                    ios { swipePointToPoint(startX: 200, startY: 550, endX: 200, endY: 250, durationSeconds: 0.3) }
                    android { swipePointToPoint(startX: 540, startY: 1500, endX: 540, endY: 700, durationSeconds: 0.3) }
                }.expectation {
                    textIs("#txt_swipe_dir", "swipe=up")
                }
            }
        }
    }
}
