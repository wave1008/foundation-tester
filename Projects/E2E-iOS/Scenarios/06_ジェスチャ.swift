// 06_ジェスチャ.swift
// ftester 機能: `tap` の連打カウント / `press`(長押し)と通常タップの区別 / `swipe` 4方向。
// SUT 側は SwiftUI の DragGesture / onLongPressGesture で検出する。swipe は要素を狙わず
// 画面全体を払う形(XCUITest の XCUIApplication.swipeUp() 等)で撃たれるため、
// #pad_swipe をコンテンツ領域いっぱいに敷いてある(E2EAppIOS/docs/ui-contract.md)。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
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
                    press("#btn_long_press")
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
            scene(5, "上スワイプ") {
                action {
                    swipe(.up)
                }.expectation {
                    textIs("#txt_swipe_dir", "swipe=up")
                }
            }
            scene(6, "下スワイプ") {
                action {
                    swipe(.down)
                }.expectation {
                    textIs("#txt_swipe_dir", "swipe=down")
                }
            }
            scene(7, "左スワイプ") {
                action {
                    swipe(.left)
                }.expectation {
                    textIs("#txt_swipe_dir", "swipe=left")
                }
            }
            scene(8, "右スワイプ") {
                action {
                    swipe(.right)
                }.expectation {
                    textIs("#txt_swipe_dir", "swipe=right")
                }
            }
            scene(9, "リセットで全カウンタが初期値に戻る") {
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
}
