// 10_スワイプで削除.swift
// 確かめる癖: SwipeToDismissBox(行の上の横の払い = スクロールではなくジェスチャ・無効な向きは戻る)。

import FTDSL

@TestClass
class スワイプで行を削除できること {

    @Test("右から左で消え、左から右では消えない")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_swipe", scroll: .down)
                }.expectation {
                    select("#txt_swipe_count").textIs("rows=5")
                }
            }
            scene(2, "3行目を右から左へ払う") {
                action {
                    // iOS の定番: 払うと右端に「削除」ボタンが出て、それを押す
                    swipeBy("#swipe_row_3", dxRatio: -0.5, dyRatio: 0, durationSeconds: 0.3)
                    tap("削除")
                }.expectation {
                    select("#txt_swipe_result").textIs("removed=3")
                    select("#txt_swipe_count").textIs("rows=4")
                    notExist("#swipe_row_3")
                }
            }
            scene(3, "1行目を左から右へ払っても消えない") {
                action {
                    swipeBy("#swipe_row_1", dxRatio: 0.5, dyRatio: 0, durationSeconds: 0.3)
                    wait(1)
                }.expectation {
                    select("#txt_swipe_count").textIs("rows=4")
                    exist("#swipe_row_1")
                }
            }
        }
    }
}
