// 30_伸縮するヘッダ.swift
// 確かめる癖: 伸縮するヘッダ(送るとヘッダが縮む = スクロールの一部がヘッダの伸縮に食われる・縮んだヘッダの下へ行が潜る)。
// 契約は E2EXAppCMP/docs/ui-contract-wave2.md

import FTDSL

@TestClass
class 伸縮するヘッダの下の行を扱えること {

    @Draft("調査中: 縮んだヘッダの echo を OCR だけの判定が「描かれていない」とした(FM が止まった Mac)")
    @Test("縮むヘッダの下の行へスクロール探索で届き、上端へ戻すとヘッダが戻る")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_collapse", scroll: .down)
                }.expectation {
                    exist("#txt_collapse_header")
                    select("#txt_collapse_result").textIs("collapse=none")
                }
            }
            scene(2, "下の行を押す") {
                action {
                    tap("#row_c_37", scroll: .down)
                }.expectation {
                    select("#txt_collapse_result").textIs("collapse=row_c_37")
                }
            }
            scene(3, "上端へ戻すと先頭の行と大きな見出し") {
                action {
                    scrollToTop()
                }.expectation {
                    exist("#row_c_00")
                    exist("#txt_collapse_header")
                }
            }
        }
    }
}
