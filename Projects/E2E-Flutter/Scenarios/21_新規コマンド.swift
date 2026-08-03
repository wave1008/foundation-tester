// 21_新規コマンド.swift
// ftester 機能: waitForDisplay/waitForClose(スクロールしない出現・消滅待ち)・verify(アサーション集約)・
// screenshot(1ステップとして埋め込み)・flick(画面基点の生ジェスチャ)・appIs(前面アプリ検証)。
// installApp/removeApp/tapAppIcon は意図的にここへ含めない(removeApp は自 SUT を消すと以降のシナリオと
// in-app ブリッジが壊れる。tapAppIcon はホーム画面依存で flake リスクが高く実機検証は別途行う)。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class 新規コマンドが正しく動くこと {

    @Test("waitForDisplay が遅延表示をスクロールなしで待つ")
    func S0010() {
        scenario {
            scene(1, "非同期表示画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_async")
                }.expectation {
                    textIs("#txt_delay_state", "state=idle")
                }
            }
            scene(2, "waitForDisplay で3秒後表示を待つ(暗黙待ちでなく明示の待機コマンド)") {
                action {
                    tap("#btn_delay_3")
                }.expectation {
                    // 戻り値は FTElement なのでそのままチェーンで検証できる
                    waitForDisplay("#txt_delayed", waitSeconds: 6)
                        .textIs("遅延表示 完了")
                    textIs("#txt_delay_state", "state=done")
                }
            }
        }
    }

    @Test("verify が複数アサーションを1ステップにまとめて passed にする")
    func S0020() {
        scenario {
            scene(1, "非同期表示画面で3秒後表示を待つ") {
                condition {
                    launchApp()
                }.expectation {
                    // 同期の1往復(S0010 scene1 と同じ罠。requireVisible: false の理由もそちら参照)
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_async")
                    tap("#btn_delay_3")
                }.expectation {
                    exist("#txt_delayed", timeout: 6)
                }
            }
            scene(2, "verify が exist と textIs をまとめて検証する") {
                expectation {
                    verify("遅延表示が完了し、状態表示も done になっていること") {
                        exist("#txt_delayed")
                        textIs("#txt_delay_state", "state=done")
                    }
                }
            }
        }
    }

    @Test("screenshot が1ステップとして記録される")
    func S0030() {
        scenario {
            scene(1, "画面を開いてスクリーンショットを撮る") {
                condition {
                    launchApp()
                }.expectation {
                    // 同期の1往復(S0010 scene1 と同じ罠。requireVisible: false の理由もそちら参照)
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_async")
                    screenshot(filename: "S0030_async")
                }.expectation {
                    textIs("#txt_delay_state", "state=idle")
                }
            }
        }
    }

    @Test("flickBottomToTop でリストが動く")
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
        }
    }

    @Test("appIs が自 SUT の bundle ID/package を検証する")
    func S0050() {
        scenario {
            scene(1, "起動直後、appIs が自身の bundle ID/package を検証する") {
                condition {
                    launchApp()
                }.expectation {
                    // 同期の1往復(S0010 scene1 と同じ罠。requireVisible: false の理由もそちら参照)
                    exist("#txt_home_marker", requireVisible: false)
                    // Flutter は iOS/Android とも同じ bundle ID(com.ftester.e2e.flutter)を使う
                    appIs("com.ftester.e2e.flutter")
                }
            }
        }
    }

    // ナビ項目はホーム画面にしかないため、別画面から続けて #nav_* を叩けない
    // (シナリオは「launchApp から1画面に入る」構成が正。S0010 と分けたのはそのため)
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
                    textIs("#txt_dialog_result", "dialog=none")
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
                    textIs("#txt_dialog_result", "dialog=ok")
                }
            }
        }
    }
}
