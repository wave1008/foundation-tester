// 06_ジェスチャ.swift
// ftester 機能: `tap` の連打カウント / `tap(holdSeconds:)`(長押し)と通常タップの区別 / `swipe` 4方向。
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
                    select("#txt_tap_count").textIs("tap=0")
                }
            }
            scene(2, "タップ3回でカウントが3になる") {
                action {
                    tap("#btn_tap_counter")
                    tap("#btn_tap_counter")
                    tap("#btn_tap_counter")
                }.expectation {
                    select("#txt_tap_count").textIs("tap=3")
                    select("#txt_last_gesture").textIs("last=tap")
                }
            }
            scene(3, "長押しでカウントが1になる") {
                action {
                    tap("#btn_long_press", holdSeconds: 1.0)
                }.expectation {
                    select("#txt_press_count").textIs("press=1")
                    select("#txt_last_gesture").textIs("last=longpress")
                }
            }
            scene(4, "通常タップでは長押しカウントが増えない(区別の検証)") {
                action {
                    tap("#btn_long_press")
                }.expectation {
                    select("#txt_press_count").textIs("press=1")
                }
            }
            scene(5, "holdSeconds 指定の長押しも検出される(既定 1 秒以外が実際に届いていること)") {
                action {
                    tap("#btn_long_press", holdSeconds: 2.0)
                }.expectation {
                    select("#txt_press_count").textIs("press=2")
                    select("#txt_last_gesture").textIs("last=longpress")
                }
            }
            scene(6, "上スワイプ") {
                action {
                    swipe(.up)
                }.expectation {
                    select("#txt_swipe_dir").textIs("swipe=up")
                }
            }
            scene(7, "下スワイプ") {
                action {
                    swipe(.down)
                }.expectation {
                    select("#txt_swipe_dir").textIs("swipe=down")
                }
            }
            scene(8, "左スワイプ") {
                action {
                    swipe(.left)
                }.expectation {
                    select("#txt_swipe_dir").textIs("swipe=left")
                }
            }
            scene(9, "右スワイプ") {
                action {
                    swipe(.right)
                }.expectation {
                    select("#txt_swipe_dir").textIs("swipe=right")
                }
            }
            scene(10, "リセットで全カウンタが初期値に戻る") {
                action {
                    tap("#btn_gesture_reset")
                }.expectation {
                    select("#txt_tap_count").textIs("tap=0")
                    select("#txt_press_count").textIs("press=0")
                    select("#txt_swipe_dir").textIs("swipe=-")
                    select("#txt_last_gesture").textIs("last=-")
                }
            }
        }
    }

    @Test("swipePointToPoint が座標スワイプとして認識される")
    func S0020() {
        scenario {
            scene(1, "座標指定で上スワイプする") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_gesture")
                    // x=200 は中央列(#pad_swipe の幅の約半分)。ui-contract の配置制約により
                    // 操作要素は幅45%以内・中央行(y=0.5h)を避けて置かれるため、この列は空いている保証がある。
                    swipePointToPoint(startX: 200, startY: 550, endX: 200, endY: 250, durationSeconds: 0.3)
                }.expectation {
                    select("#txt_swipe_dir").textIs("swipe=up")
                }
            }
        }
    }
}
