// 19_OCRで読める薄いテキスト.swift
// occlusion-guard の Tier-2(Vision OCR)段を通す witness。E2EAppIOS の同名シナリオを CMP へ移植。
// `#txt_ocr_faint`(診断画面)は白地固定・gray 220/255・160x44dp・17sp でインクを薄くしてあり、
// Tier-1 の足切り(既定 12)を通らず Tier-2 の OCR 判定(期待文字列 `ocr=readable` が丸ごと
// 読めれば FM を省く)まで届く。**色・枠・フォントサイズは変えない**(値の根拠は
// E2EAppCMP/docs/ui-contract.md「診断画面」節)。

import FTDSL

@TestClass
class 薄いテキストがOCRまで届いて読めること {

    @Test("Tier-1の足切りを通り抜けてOCRまで届き、読めれば素通りする")
    func S0010() {
        scenario {
            scene(1, "診断画面を開いて OCR witness を確かめる") {
                condition {
                    launchApp()
                    tap("#nav_diagnostics", scroll: .down)
                }.expectation {
                    select("#txt_ocr_faint", scroll: .down).textIs("ocr=readable")
                }
            }
        }
    }
}
