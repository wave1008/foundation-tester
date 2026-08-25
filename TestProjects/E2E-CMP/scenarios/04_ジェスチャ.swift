// 04_ジェスチャ.swift
// fleetest 機能: `tap` の連打カウント / `tap(holdSeconds:)`(長押し)と通常タップの区別 / `swipe` 4方向 /
// `swipePointToPoint`(座標スワイプ)/ `pinchOut`/`pinchIn`(2本指ズーム)/ `doubleTap` /
// `swipeBy`(斜めを含む相対ドラッグ)をまとめて検証する。
// 旧シナリオ境界は tap("#tab_home") でホームへ戻ってから叩き直す形に置き換えてある
// (App() はタブ/子画面切替で remember 状態を破棄するため、tap=0 等の初期値はこれだけで戻る)。

import FTDSL

@TestClass
class ジェスチャが正しく検出されること {

    @Test("タップ連打・長押し・4方向スワイプ・座標スワイプ・ピンチ・ダブルタップ・斜めドラッグが区別して検出される")
    func S0010() {
        scenario {
            scene(1, "06.S0010: ジェスチャ画面を開く") {
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
            scene(11, "06.S0020: swipePointToPoint が座標スワイプとして認識される") {
                condition {
                    tap("#tab_home")
                }.action {
                    tap("#nav_gesture")
                    // 座標は snapshot の screen 座標系(iOS pt / Android px)。中央列(x=0.5w 付近)は
                    // ui-contract のジェスチャ画面レイアウト制約により操作要素が置かれず空いている
                    ios { swipePointToPoint(startX: 200, startY: 550, endX: 200, endY: 250, durationSeconds: 0.3) }
                    android { swipePointToPoint(startX: 540, startY: 1500, endX: 540, endY: 700, durationSeconds: 0.3) }
                }.expectation {
                    select("#txt_swipe_dir").textIs("swipe=up")
                }
            }
            scene(12, "22.S0010: ピンチ・ダブルタップ・斜めドラッグが区別して検出される") {
                condition {
                    tap("#tab_home")
                }.action {
                    // マップ画面はジェスチャ画面から開く(ホームのナビ行を増やすと
                    // 末尾が下部タブに重なる。E2EAppCMP/docs/ui-contract.md)
                    tap("#nav_gesture")
                    tap("#nav_map")
                }.expectation {
                    select("#txt_zoom_dir").textIs("zoom=-")
                    select("#txt_double_count").textIs("double=0")
                }
            }
            scene(13, "ピンチアウトで拡大が検出される") {
                action {
                    pinchOut("#pad_map", scale: 2.0)
                }.expectation {
                    select("#txt_zoom_dir").textIs("zoom=in")
                }
            }
            scene(14, "ピンチインで縮小が検出される") {
                action {
                    tap("#btn_map_reset")
                    pinchIn("#pad_map", scale: 0.5)
                }.expectation {
                    select("#txt_zoom_dir").textIs("zoom=out")
                }
            }
            scene(15, "単タップではダブルタップカウントが増えない(区別の検証)") {
                action {
                    tap("#btn_map_reset")
                    tap("#pad_map")
                }.expectation {
                    select("#txt_double_count").textIs("double=0")
                }
            }
            // **iOS の Compose はエンジンで割れる**: 既定の hybrid(in-app)なら通るが、
            // XCUITest 単独では合成2打の間隔が詰まりすぎて単タップに落ちる(2026-08-04 実測・
            // docs/commands.md)。このシナリオは両エンジンで走るので Android に閉じる ——
            // iOS の doubleTap は E2E-iOS(SwiftUI)と E2E-Flutter が担保する
            scene(16, "ダブルタップでカウントが1増える(iOS はエンジン差のため対象外)") {
                action {
                    android { doubleTap("#pad_map") }
                }.expectation {
                    android { select("#txt_double_count").textIs("double=1") }
                }
            }
            scene(17, "左上への斜めドラッグが両軸で検出される") {
                action {
                    tap("#btn_map_reset")
                    swipeBy("#pad_map", dxRatio: -0.4, dyRatio: -0.4)
                }.expectation {
                    // 両軸とも非 none = 斜めに動いたこと(縦横だけなら片方が none になる)
                    select("#txt_pan").textIs("pan=left-up")
                }
            }
            scene(18, "右下への斜めドラッグ") {
                action {
                    tap("#btn_map_reset")
                    swipeBy("#pad_map", dxRatio: 0.4, dyRatio: 0.4)
                }.expectation {
                    select("#txt_pan").textIs("pan=right-down")
                }
            }
            scene(19, "対象を指定しないジェスチャは画面全体に効く") {
                action {
                    tap("#btn_map_reset")
                    pinchOut()
                }.expectation {
                    select("#txt_zoom_dir").textIs("zoom=in")
                }
            }
            scene(20, "リセットで全ての値が初期状態に戻る") {
                action {
                    tap("#btn_map_reset")
                }.expectation {
                    select("#txt_zoom_dir").textIs("zoom=-")
                    select("#txt_zoom").textIs("zoom=1.0")
                    select("#txt_pan").textIs("pan=-")
                    select("#txt_double_count").textIs("double=0")
                }.action {
                    tap("#tab_home")
                }
            }
        }
    }
}
