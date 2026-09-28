// 35_並べ替え.swift
// 確かめる癖: ドラッグでの並べ替え(長押ししてから指を離さずに動かす = gesture でしか書けない)。

import FTDSL

@TestClass
class ドラッグで並べ替えられること {

    @Test("1行目を長押しして3行目の位置へ動かす")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_reorder", scroll: .down)
                }.expectation {
                    select("#txt_reorder_result").textIs("order=1,2,3,4,5")
                }
            }
            scene(2, "並べ替える") {
                action {
                    // 座標は #reorder_row_1 の枠に対する比率。y=2.5 = 2行ぶん下(行の高さが揃っている前提)
                    gesture("#reorder_row_1") {
                        FTFinger(x: 0.5, y: 0.5).hold(seconds: 0.8)
                            .move(x: 0.5, y: 2.5, durationSeconds: 1.0)
                            .hold(seconds: 0.3)
                    }
                }.expectation {
                    // 着地位置はフレームワークで前後する(何行ぶん動かすと1行進むかの判定が部品ごとに違う。
                    // 同じ 2 行ぶんで CMP・Flutter は1つ下、RN は末尾)。1行目が下へ移ったことを確かめる
                    select("#txt_reorder_result").textMatches("^order=2,")
                }
            }
        }
    }
}
