// 21_新規コマンド.swift
// ftester 機能: waitForDisplay/waitForClose(スクロールしない出現・消滅待ち)・verify(アサーション集約)・
// screenshot(1ステップとして埋め込み)・flick(画面基点の生ジェスチャ)・appIs(前面アプリ検証)。
// installApp/removeApp/tapAppIcon は意図的にここへ含めない(removeApp は自 SUT を消すと以降のシナリオと
// in-app ブリッジが壊れる。tapAppIcon はホーム画面依存で flake リスクが高く実行での検証は別途行う)。
//
// **同じ画面で始まるものは1本にまとめる**(2026-08-04 統合。Flutter/iOS/Android 版から踏襲)。
// appIs / screenshot / waitForDisplay / verify は「起動 → 非同期表示画面」という同一の導入を
// 4回繰り返しており、1本あたり launchApp + ナビの固定費だけが増えていた(全 E2E スイートは
// 合計律速 = docs/performance-tuning.md §3.6)。**別画面のものは分けたまま**
// (flick=スクロール画面 / waitForClose=ダイアログ画面)。ナビ項目はホーム画面にしかないため、
// 別画面から続けて #nav_* を叩けない。統合で、起動直後の同期の1往復(下記)も4か所から1か所に減る。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class 新規コマンドが正しく動くこと {

    @Test("appIs・screenshot・waitForDisplay・verify が非同期表示画面で動く")
    func S0010() {
        scenario {
            scene(1, "起動直後、appIs が自身の bundle ID/package を検証する") {
                condition {
                    launchApp()
                }.expectation {
                    // 起動直後は a11y ツリー完成後もポインタ入力を一時的に取りこぼす実装が
                    // Flutter で実測されている。RN で同じ罠があるかは未検証だが、害の無い
                    // 1往復なので安全側として残す。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                    // RN も iOS/Android とも同じ bundle ID(com.ftester.e2e.rn)を使う
                    appIs("com.ftester.e2e.rn")
                }
            }
            scene(2, "非同期表示画面を開いてスクリーンショットを撮る") {
                action {
                    tap("#nav_async")
                    screenshot(filename: "S0010_async")
                }.expectation {
                    select("#txt_delay_state").textIs("state=idle")
                }
            }
            scene(3, "waitForDisplay で3秒後表示を待つ(暗黙待ちでなく明示の待機コマンド)") {
                action {
                    tap("#btn_delay_3")
                }.expectation {
                    // 戻り値は FTElement なのでそのままチェーンで検証できる
                    waitForDisplay("#txt_delayed", waitSeconds: 6)
                        .textIs("遅延表示 完了")
                    select("#txt_delay_state").textIs("state=done")
                }
            }
            scene(4, "verify が exist と textIs をまとめて1ステップにする") {
                expectation {
                    verify("遅延表示が完了し、状態表示も done になっていること") {
                        exist("#txt_delayed")
                        select("#txt_delay_state").textIs("state=done")
                    }
                }
            }
        }
    }

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

    @Test("waitForClose がダイアログの消滅を待つ")
    func S0060() {
        scenario {
            scene(1, "ダイアログ画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // 同期の1往復(S0010 scene1 と同じ罠。requireVisible: false の理由もそちら参照)
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_dialog")
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=none")
                }
            }
            scene(2, "ダイアログを開いて OK し、waitForClose で閉じるのを待つ") {
                action {
                    tap("#btn_show_dialog")
                }.expectation {
                    exist("#txt_dialog_title")
                }.action {
                    tap("#btn_dialog_ok")
                    waitForClose("#txt_dialog_title", waitSeconds: 5)
                }.expectation {
                    select("#txt_dialog_result").textIs("dialog=ok")
                }
            }
        }
    }
}
