// 15_OCRで読める薄いテキスト.swift
// occlusion-guard の Tier-2(Vision OCR)段を通す回帰。witness は E2EAppRN の
// `#txt_ocr_faint`(診断画面)。guard は「幾何で無罪 かつ 領域にインクがある」なら
// Tier-1(輝度足切り)で FM を省くが、この対象はインクを薄くしてあり Tier-1 を通らない。
// Tier-1 を通らなかった crop だけが Tier-2(OCR)へ行き、期待文字列 `ocr=readable` が
// 丸ごと読めれば FM を省いて素通りする。
// 色(gray220)・枠(160x44)・フォントサイズ(17pt)は実測で決めた値で、変えると
// witness が死ぬ(値の根拠は E2EAppCMP/docs/ui-contract.md §診断画面)。
// platform 未指定 = ios/android 両プロファイルで回す。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class OCRで読める薄いテキスト {

    @Test("薄い文字は Tier-1 を通り抜けて OCR まで届き、読めれば素通りする")
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
