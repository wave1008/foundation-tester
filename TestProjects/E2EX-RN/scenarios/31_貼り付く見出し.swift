// 31_貼り付く見出し.swift
// 確かめる癖: 貼り付く見出し(見出しが上端に残って下の行を覆う = 見出しの下に潜った行を押すと見出しに当たる)。

import FTDSL

@TestClass
class 貼り付く見出しのリストを扱えること {

    @Test("下のセクションの行へ届き、見出しが上端に貼り付いている")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_sticky", scroll: .down)
                }.expectation {
                    select("#txt_sticky_result").textIs("sticky=none")
                    exist("#hdr_A")
                }
            }
            scene(2, "F セクションの行") {
                action {
                    tap("#row_s_F3", scroll: .down)
                }.expectation {
                    select("#txt_sticky_result").textIs("sticky=row_s_F3")
                    exist("#hdr_F")
                }
            }
            scene(3, "上へ戻って B セクションの行") {
                action {
                    tap("#row_s_B1", scroll: .up)
                }.expectation {
                    select("#txt_sticky_result").textIs("sticky=row_s_B1")
                }
            }
        }
    }
}
