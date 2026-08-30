// 12_フリック.swift
// fleetest 機能: `flick` 8方向(画面基点の生ジェスチャ)がスクロール容器と横カルーセルを動かすことの検証。
// appIs/screenshot/waitForDisplay/verify は 06_待機とタイムアウト.swift、
// waitForClose は 07_条件分岐とダイアログ.swift へ統合済み(同じ画面の launchApp を共有するため)。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class フリックが正しく動くこと {

    @Test("flick 8方向がスクロール容器と横カルーセルを実際に動かす")
    func S0010() {
        scenario {
            scene(1, "スクロール画面を開く") {
                condition {
                    launchApp()
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
            // **戻り方向は端で撃つ**。フリングの距離は往路と復路で対称ではなく
            // (Android 実測 2026-08-04: 往路で 行15 付近まで送られ、復路を3回撃っても 行08 止まり)、
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
                    // 戻しは**フリックではなく端送り**(距離に依存させない)。scrollLeft×N は
                    // 1回の刻み(横 370px の容器で 221px)× N が慣性距離(約 700〜770px)に届かず、
                    // 先頭タグが部分可視かどうかの数十 px で合否が割れていた(2026-08-30 実測)
                    scrollToLeftEdge(scrollFrame: "#carousel_tags")
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
                    scrollToLeftEdge(scrollFrame: "#carousel_tags")
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
