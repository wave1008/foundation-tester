// 40_無限スクロール.swift
// 確かめる癖: 末尾で続きを読み込む一覧(送るたびに端が遠ざかる・読み込み中の行)。

import FTDSL

@TestClass
class 無限スクロールの先の行へ届くこと {

    @Test("読み込みを重ねた先の行を押す")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_infinite", scroll: .down)
                }.expectation {
                    select("#txt_infinite_count").textIs("loaded=20")
                }
            }
            scene(2, "57 行目") {
                action {
                    tap("#row_i_57", scroll: .down, maxSwipes: 30)
                }.expectation {
                    select("#txt_infinite_result").textIs("infinite=row_i_57")
                    select("#txt_infinite_count").textMatches("^loaded=(60|80|100)$")
                }
            }
        }
    }
}
