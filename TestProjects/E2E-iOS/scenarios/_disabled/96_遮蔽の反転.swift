// 96_遮蔽の反転.swift
// **陽性対照**(既定スイートには載せない): occlusion-guard が **FM に訊いて反転する経路**を
// デバイスで通す。95_可視性の幾何 が確かめるのは幾何 Tier-0(中心が画面外)で、**FM は呼ばれない**。
//
// **なぜ要るか**: 2026-09-03 に occlusion の呼び出しを2段構えにした(1段目 = reason を作らせない
// 選別 / 1段目が「見えていない」と答えた回だけ2段目 = 従来と同じ4欄が判定・失敗文言・crop 保存を
// 行う)。**2段目に落ちる経路は緑の run では1度も実行されない** —— 導入時の実機確認でも
// occlusion 17 回すべてが1段目で「見えている」と終わった。壊しても沈黙する場所なので、
// 経路を強制的に通す対照がここに要る。
//
// **witness は `#btn_paint_target`**(無地の不透明な面で覆われるボタン)。覆いに文字が無いことが
// 要点で、文字があると guard は Tier-1(幾何で無罪 かつ インクあり → FM を省く)で素通りする
// —— 既存の覆い(タブバー・別ウィンドウのモーダル)はどちらもインクがあり、実測で FM 呼び出しは
// 0 だった(docs/verification.md)。
//
// 回し方: このファイルを scenarios/ 直下へ一時的に出し、`falsePositiveCheck: true` の
// プロファイルで回す:
//   fleetest run --project E2E-iOS --profile ios-fpc --scenario 遮蔽の反転
// **S0010 は落ちるのが正常**。見るのは合否ではなく次の3つ:
//   ① 失敗文言が `false positive (occlusion)` で、`[state]` と reason と observed= が付いている
//      (**reason が空なら2段目に落ちていない** = 1段目の結果をそのまま返している)
//   ② 結果 JSON の `fm.byKind.occlusion.calls` が反転1回につき **2** 増える(選別 + 詳細)
//   ③ `~/Library/Logs/fleetest/occlusion/` に crop が保存される(2段目だけが書く)
// S0020 は陰性対照(覆いを外せば同じ要素が通る)。
import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class 遮蔽の反転 {

    @Test("無地の面で覆われた要素への exist は FM 判定で反転する(落ちるのが正常)")
    func S0010() {
        scenario {
            scene(1, "覆いを塗ってから対象を確かめる") {
                condition {
                    launchApp()
                    tap("#nav_cover", scroll: .down)
                    exist("#btn_paint_target")
                }.action {
                    tap("#btn_toggle_paint")
                }.expectation {
                    // 木には居り、画面内にも居る。覆いは無地なので Tier-1 のインク足切りを
                    // 通過し、**FM に訊く経路だけ**が反転を出せる
                    existWithoutScroll("#btn_paint_target")
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
                    existWithoutScroll("#btn_paint_target")
                }
            }
        }
    }
}
