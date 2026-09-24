// 22_連続ジェスチャ.swift
// fleetest 機能: `gesture`(指が離れない1本の連続タッチ列。`FTFinger` を `hold`/`move` で繋いで
// 折れ線・複数指を1回のタッチとして撃つ)を検証する。
// `#txt_pan`(移動量の累積)だけでは「1回の連続ジェスチャ」と「途中で指を離して撃ち直した
// 複数回のジェスチャ」を区別できないため、`#txt_drag_count`(完了したドラッグの回数)を
// 判別材料に使う(E2EAppCMP/docs/ui-contract.md §マップ画面)。

import FTDSL

@TestClass
class 連続ジェスチャが1回のタッチ列として検出されること {

    @Test("保持を挟んだ折れ線・2本指の同時移動・タップの空振りが drag カウントで区別される")
    func S0010() {
        scenario {
            scene(1, "マップ画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_gesture")
                    tap("#nav_map")
                }.expectation {
                    select("#txt_pan").textIs("pan=-")
                    select("#txt_drag_count").textIs("drag=0")
                }
            }
            scene(2, "保持を挟んだ1本指の折れ線ドラッグは、指が離れるまで1回のドラッグとして数えられる") {
                action {
                    tap("#btn_map_reset")
                    gesture("#pad_map") {
                        FTFinger(x: 0.3, y: 0.35)
                            .hold(seconds: 0.3)
                            .move(x: 0.6, y: 0.35, durationSeconds: 0.3)
                            .move(x: 0.6, y: 0.65, durationSeconds: 0.3)
                    }
                }.expectation {
                    // pan は開始点から終了点までの移動方向(右下)。drag=1 が
                    // 「1本の折れ線 = 1回のドラッグ」であることの判別材料(pan だけでは
                    // 2回に分けて撃った場合と区別できない)
                    select("#txt_pan").textIs("pan=right-down")
                    select("#txt_drag_count").textIs("drag=1")
                }
            }
            scene(3, "2本指を同時に外側へ動かす連続ジェスチャも効く") {
                action {
                    tap("#btn_map_reset")
                    gesture("#pad_map") {
                        FTFinger(x: 0.45, y: 0.5).move(x: 0.2, y: 0.5, durationSeconds: 0.5)
                        FTFinger(x: 0.55, y: 0.5).move(x: 0.8, y: 0.5, durationSeconds: 0.5)
                    }
                }.expectation {
                    select("#txt_zoom_dir").textIs("zoom=in")
                }
            }
            scene(4, "同じ折れ線を2回に分けて撃つと2回のドラッグとして数えられる(scene 2 の対照)") {
                action {
                    tap("#btn_map_reset")
                    gesture("#pad_map") {
                        FTFinger(x: 0.3, y: 0.35).move(x: 0.6, y: 0.35, durationSeconds: 0.3)
                    }
                    gesture("#pad_map") {
                        FTFinger(x: 0.6, y: 0.35).move(x: 0.6, y: 0.65, durationSeconds: 0.3)
                    }
                }.expectation {
                    // カウンタが常に1で止まる壊れ方だと scene 2 の drag=1 は判別にならない。
                    // 指が離れれば数が増えることをここで確かめる
                    select("#txt_pan").textIs("pan=right-down")
                    select("#txt_drag_count").textIs("drag=2")
                }
            }
            scene(5, "パッドをタップしただけではドラッグとして数えない(誤検知の否定側)") {
                action {
                    tap("#btn_map_reset")
                    tap("#pad_map")
                }.expectation {
                    select("#txt_drag_count").textIs("drag=0")
                }.action {
                    tap("#tab_home")
                }
            }
        }
    }
}
