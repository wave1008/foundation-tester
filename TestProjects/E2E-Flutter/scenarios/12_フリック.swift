// 12_フリック.swift
// ftester 機能: flick(画面基点の生ジェスチャ。8方向)。
// installApp/removeApp/tapAppIcon は意図的にここへ含めない(removeApp は自 SUT を消すと以降のシナリオと
// in-app ブリッジが壊れる。tapAppIcon はホーム画面依存で flake リスクが高く実行での検証は別途行う)。
// **appIs/screenshot/waitForDisplay/verify は 06_待機とタイムアウト.swift(旧 S0010)へ、
// waitForClose は 07_条件分岐とダイアログ.swift(旧 S0060)へ移設した**(2026-08-08 統合。
// いずれも「起動 → 非同期表示画面」/「ダイアログ画面」という同一導入の重複を減らすため)。
// flick はスクロール画面専用の操作でナビ経路が異なるため、この統合には含めず単独 @Test のまま残す。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class フリックが正しく動くこと {

    @Test("flick 8方向がスクロール容器と横カルーセルを実際に動かす")
    func S0010() {
        scenario {
            scene(1, "スクロール画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    // requireVisible: false = 可視性の**検証**ではなく同期のための1往復
                    // (詳細は 01_起動と画面遷移.swift・README「既知の ftester 欠陥」参照)。
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
