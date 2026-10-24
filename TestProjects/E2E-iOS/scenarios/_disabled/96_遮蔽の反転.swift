// 96_遮蔽の反転.swift
// **陽性対照**(既定スイートには載せない): occlusion-guard が **FM に訊いて反転する経路**を
// デバイスで通す。95_可視性の幾何 が確かめるのは幾何 Tier-0(中心が画面外)で、**FM は呼ばれない**。
//
// **なぜ要るか**: FM の転写が期待文字列を読めずに赤へ反転する経路は**緑の run では1度も実行されない**
// (緑の run の FM 呼び出しはどれも「読めた」で終わる)。壊しても沈黙する場所なので、経路を強制的に通す対照がここに要る。
//
// **witness は `#txt_paint_target`**(無地の不透明な面で覆われるテキスト)。覆いに文字が無いことが
// 要点で、文字があると guard は Tier-1(幾何で無罪 かつ インクあり → FM を省く)で素通りする
// —— 既存の覆い(タブバー・別ウィンドウのモーダル)はどちらもインクがあり、実測で FM 呼び出しは
// 0 だった(docs/verification.md)。**対象がテキストであることも必須** ——
// `OcclusionEligibility` はテキスト型だけを FM に回すので、Button だと足切りで素通りする。
//
// 回し方: このファイルを scenarios/ 直下へ一時的に出し、`fmTextVisibilityCheck: true` の
// プロファイルで回す:
//   fleetest run --project E2E-iOS --profile ios-fpc --scenario 遮蔽の反転
// **S0010 は落ちるのが正常**。見るのは合否ではなく次の3つ:
//   ① 失敗文言が `text visibility check failed (on screen)` で、`[state]` と reason と observed= が付いている
//      (`judged by OCR alone` なら FM を通っていない)
//   ② 結果 JSON の `fm.byKind.occlusion.calls` が 1 以上(今の実装は等倍で読めなければ拡大して読み直すので反転1回に
//      2 回だが、回数は拡大の読み直しの有無で変わる = 表は 1 以上だけを見る)
//   ③ `~/Library/Logs/fleetest/occlusion/` に crop が保存される(不可視と判定した回に書く)
// S0020 は陰性対照(覆いを外せば同じ要素が通る)。**S0020 では FM は呼ばれない** ——
// 覆いを外すと文字が戻ってインク量が上がり、Tier-1 の足切りで FM を省くため(それが正しい挙動)。
//
// **2026-09-03 の実測**(M1Max・inapp モード・当時の `textVisualCheck: true` = 今の `fmTextVisibilityCheck: true`・当時の失敗文言 `false positive (occlusion)` = 今の `text visibility check failed (on screen)`):
//   S0010 → `false positive (occlusion): present in the tree but not visually visible [covered]
//            Text is covered by a solid color overlay [crop: …] observed=""`
//   fm.byKind.occlusion.calls = 2(当時は選別 + 詳細の2段。今は等倍 + 拡大の読み直し)/ crop も保存された / S0020 は緑・FM 呼び出し 0。
import FTDSL

@TestClass(platform: "ios")
class 遮蔽の反転 {

    @Test("無地の面で覆われた要素への exist は FM 判定で反転する(落ちるのが正常)")
    func S0010() {
        scenario {
            scene(1, "覆いを塗ってから対象を確かめる") {
                condition {
                    launchApp()
                    tap("#nav_cover", scroll: .down)
                    exist("#txt_paint_target")
                }.action {
                    tap("#btn_toggle_paint")
                }.expectation {
                    // 木には居り、画面内にも居る。覆いは無地なので Tier-1 のインク足切りを
                    // 通過し、**FM に訊く経路だけ**が反転を出せる
                    exist("#txt_paint_target", scroll: .noScroll)
                }
            }
        }
    }

    @Test("覆いを外せば同じ要素が通る(陰性対照)")
    func S0020() {
        scenario {
            scene(1, "塗って外す") {
                condition {
                    launchApp()
                    tap("#nav_cover", scroll: .down)
                    tap("#btn_toggle_paint")
                }.action {
                    tap("#btn_toggle_paint")
                }.expectation {
                    exist("#txt_paint_target", scroll: .noScroll)
                }
            }
        }
    }
}
