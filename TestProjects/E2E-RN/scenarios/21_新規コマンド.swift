// 21_新規コマンド.swift
// ftester 機能: flick(画面基点の生ジェスチャ)8方向がスクロール容器と横カルーセルを実際に動かす。
// installApp/removeApp/tapAppIcon は意図的にここへ含めない(removeApp は自 SUT を消すと以降のシナリオと
// in-app ブリッジが壊れる。tapAppIcon はホーム画面依存で flake リスクが高く実行での検証は別途行う)。
//
// **appIs/screenshot/waitForDisplay/verify(旧 S0010)は 08_待機とタイムアウト.swift へ、
// waitForClose(旧 S0060)は 09_条件分岐とダイアログ.swift へ移設した**(2026-08-08。同じ画面
// (非同期表示・ダイアログ)を舞台にする他クラスタへ合流させ launchApp を減らすため)。
// flick は舞台がスクロール画面で他クラスタと共有できないためこのファイルに残る。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class 新規コマンドが正しく動くこと {

    @Test("flick 8方向がスクロール容器と横カルーセルを実際に動かす")
    func S0040() {
        scenario {
            scene(1, "スクロール画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // 同期の1往復(S0010 scene1 と同じ罠。requireVisible: false の理由もそちら参照)
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    exist("#row_01")
                }
            }
            scene(2, "flickBottomToTop で #list_rows を送ると先頭行が画面外へ流れる") {
                action {
                    flickBottomToTop(scrollFrame: "#list_rows")
                }.expectation {
                    // 慣性距離に依存しない緩い検証: 「動いた」ことだけを見る(何行分かは問わない)
                    notExist("#row_01")
                }
            }
            // **戻り方向は端で撃つ**。フリングの距離は往路と復路で対称ではなく、
            // 「先頭へ戻り切る」を期待値にすると SUT ごとに落ちる。端で撃てば**動かないのが正しい**ので、
            // 逆向きに実装されていれば #row_01 が流れて落ちる = 方向だけを決定的に固定できる
            // (距離と座標は Tests/FTCoreTests/ScrollGeometryTests.swift が持つ)
            scene(3, "先頭へ戻し、端で flickTopToBottom / flickCenterToBottom を撃っても先頭行は残る") {
                action {
                    tap("#btn_scroll_top")
                }.expectation {
                    exist("#row_01")
                }.action {
                    flickTopToBottom(scrollFrame: "#list_rows")
                    flickCenterToBottom(scrollFrame: "#list_rows")
                }.expectation {
                    exist("#row_01")
                }
            }
            scene(4, "flickCenterToTop も中央基点で先頭行を流す") {
                action {
                    flickCenterToTop(scrollFrame: "#list_rows")
                }.expectation {
                    notExist("#row_01")
                }
            }
            scene(5, "横カルーセルは flickRightToLeft / flickCenterToLeft で送れる") {
                action {
                    flickRightToLeft(scrollFrame: "#carousel_tags")
                }.expectation {
                    notExist("#tag_01")
                }.action {
                    // 戻しは**フリックではなく決定的な scrollLeft**(距離に依存させない)
                    scrollLeft(scrollFrame: "#carousel_tags", repeat: 3)
                }.expectation {
                    exist("#tag_01")
                }.action {
                    flickCenterToLeft(scrollFrame: "#carousel_tags")
                }.expectation {
                    notExist("#tag_01")
                }
            }
            scene(6, "左端に戻し、端で flickLeftToRight / flickCenterToRight を撃っても先頭タグは残る") {
                action {
                    scrollLeft(scrollFrame: "#carousel_tags", repeat: 3)
                }.expectation {
                    exist("#tag_01")
                }.action {
                    flickLeftToRight(scrollFrame: "#carousel_tags")
                    flickCenterToRight(scrollFrame: "#carousel_tags")
                }.expectation {
                    exist("#tag_01")
                }
            }
        }
    }
}
