// 15_OCRで読める薄いテキスト.swift
// occlusion-guard の Tier-2(Vision OCR)段を通す回帰。witness は E2EAppAndroid の
// `#txt_ocr_faint`(診断画面・View/XML の TextView)。guard は「幾何で無罪 かつ 領域に
// インクがある」なら Tier-1 で FM を省くが、この対象はインクを薄くしてあり Tier-1 の
// 足切り(既定 12)を通らない。Tier-1 を通らなかった crop だけが Tier-2(OCR)へ行き、
// 期待文字列 `ocr=readable` が丸ごと読めれば FM を省いて素通りする(E2EAppIOS 版 19 と対)。
//
// **色(gray220)・枠(160x44dp)・フォントサイズ(17sp)を変えない** —— 変えると輝度の
// stdDev が足切りを超え、Tier-1 で素通りして Tier-2 に届かなくなる(値の根拠は
// E2EAppCMP/docs/ui-contract.md §診断画面)。背景は白へ直値で固定してあり DayNight で反転しない。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
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
