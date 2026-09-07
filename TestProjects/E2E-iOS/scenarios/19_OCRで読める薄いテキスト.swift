// occlusion-guard の Tier-2(Vision OCR)段を通す回帰。
//
// witness は E2EAppIOS の `#txt_ocr_faint`(診断画面)。guard は「幾何で無罪 かつ 領域に
// インクがある」なら Tier-1 で FM を省くが、この対象はインクを薄くしてあり Tier-1 の
// 足切り(既定 12)を通らない。Tier-1 を通らなかった crop だけが Tier-2(OCR)へ行き、
// 期待文字列 `ocr=readable` が丸ごと読めれば FM を省いて素通りする。
//
// **自前 SUT に他にこの形の画面が無く**、Tier-2 に届く実測が皆無だった(114 件中 2 件のみ)。
// つまり実行プロファイルの `ocrFalsePositiveCheck` を切り替えても、デバイス実行では
// 結果が1バイトも変わらないまま緑になっていた。この1本が緑で通る限り、
// `#txt_ocr_faint` は木に居て・見えていて・Tier-2 へ実際に届いている。
//
// **色(gray220)・枠(160x44)・フォントサイズ(17pt)を変えない** —— 変えると輝度の
// stdDev が足切りを超え、Tier-1 で素通りして Tier-2 に届かなくなる(値の根拠は
// E2EAppCMP/docs/ui-contract.md §診断画面)。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
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
