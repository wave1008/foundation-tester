// 06_待機とタイムアウト.swift
// ftester 機能: 暗黙待ち(exist/textIs の既定タイムアウト再試行)と `timeout:` 引数の検証・
// `appIs`/`screenshot`/`waitForDisplay`/`verify`(21.S0010)・秒引数の小数指定(20.S0020)を
// まとめて検証する。
// #btn_delay_8 は既定5秒を超えるため timeout: を明示して通す(timeout が効いていることの証明であり、
// 「失敗させる」テストにはしない)。固定 wait() は暗黙待ちがあるため使わない。
// 旧シナリオ境界は tap("#tab_home") でホームへ戻ってから叩き直す形に置き換えてある
// (App() はタブ/子画面切替で remember 状態を破棄するため、state=idle 等の初期値はこれだけで戻る)。
// **S0020(timeout: の明示検証)は重量級(8秒待ち)のため統合しない**(独立 @Test のまま)。

import FTDSL

@TestClass
class 待機とタイムアウトが正しく効くこと {

    @Test("既定タイムアウト内の遅延表示は暗黙待ちで拾える・appIs/screenshot/waitForDisplay/verify・秒引数の小数指定")
    func S0010() {
        scenario {
            scene(1, "08.S0010: 既定タイムアウト内の遅延表示は暗黙待ちで拾える") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_async")
                }.expectation {
                    select("#txt_delay_state").textIs("state=idle")
                }
            }
            scene(2, "1秒後表示は既定タイムアウト内に暗黙待ちで検出される") {
                action {
                    tap("#btn_delay_1")
                }.expectation {
                    exist("#txt_delayed")
                    select("#txt_delay_state").textIs("state=done")
                }
            }
            scene(3, "21.S0010: appIs・screenshot・waitForDisplay・verify が非同期表示画面で動く") {
                condition {
                    tap("#tab_home")
                }.expectation {
                    // CMP は iOS/Android とも同じ bundle ID(com.ftester.e2e)を使う
                    appIs("com.ftester.e2e")
                }
            }
            scene(4, "非同期表示画面を開いてスクリーンショットを撮る") {
                action {
                    tap("#nav_async")
                    screenshot(filename: "S0010_async")
                }.expectation {
                    select("#txt_delay_state").textIs("state=idle")
                }
            }
            scene(5, "waitForDisplay で3秒後表示を待つ(暗黙待ちでなく明示の待機コマンド)") {
                action {
                    tap("#btn_delay_3")
                }.expectation {
                    // 戻り値は FTElement なのでそのままチェーンで検証できる
                    waitForDisplay("#txt_delayed", waitSeconds: 6)
                        .textIs("遅延表示 完了")
                    select("#txt_delay_state").textIs("state=done")
                }
            }
            scene(6, "verify が exist と textIs をまとめて1ステップにする") {
                expectation {
                    verify("遅延表示が完了し、状態表示も done になっていること") {
                        exist("#txt_delayed")
                        select("#txt_delay_state").textIs("state=done")
                    }
                }
            }
            scene(7, "20.S0020: 秒引数に小数を書ける") {
                condition {
                    tap("#tab_home")
                }.action {
                    tap("#nav_async")
                    tap("#btn_async_reset")
                }.expectation {
                    select("#txt_delay_state").textIs("state=idle")
                }
            }
            scene(8, "3秒後表示を timeout: 4.5(小数)で待てる") {
                action {
                    tap("#btn_delay_3")
                }.expectation {
                    exist("#txt_delayed", timeout: 4.5)
                    select("#txt_delay_state", timeout: 1.5).textIs("state=done", timeout: 1.5)
                }
            }
            scene(9, "ifCanSelect の waitSeconds も小数で待てる") {
                action {
                    tap("#btn_async_reset")
                    tap("#btn_delay_1")
                    // 1秒後に出る要素を 2.5 秒まで待って拾う(既定の 0 では不成立になる待ち)
                    ifCanSelect("#txt_delayed", waitSeconds: 2.5) {
                        tap("#btn_async_reset")
                    }
                }.expectation {
                    select("#txt_delay_state").textIs("state=idle")
                }.action {
                    tap("#tab_home")
                }
            }
        }
    }

    @Test("timeout: を明示して既定を超える遅延も待てる")
    func S0020() {
        scenario {
            scene(1, "非同期表示画面をリセットして開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_async")
                    tap("#btn_async_reset")
                }.expectation {
                    select("#txt_delay_state").textIs("state=idle")
                }
            }
            scene(2, "3秒後表示は timeout: 6 を明示して待つ") {
                action {
                    tap("#btn_delay_3")
                }.expectation {
                    exist("#txt_delayed", timeout: 6)
                    select("#txt_delay_state").textIs("state=done")
                }
            }
            scene(3, "カウントダウンも timeout: 3 で観測できる") {
                action {
                    tap("#btn_async_reset")
                    tap("#btn_delay_3")
                }.expectation {
                    exist("#txt_countdown", timeout: 3)
                }
            }
            scene(4, "8秒後表示は既定5秒を超えるため timeout: 12 を明示しないと拾えない") {
                action {
                    tap("#btn_async_reset")
                    tap("#btn_delay_8")
                }.expectation {
                    exist("#txt_delayed", timeout: 12)
                    select("#txt_delay_state").textIs("state=done")
                }
            }
        }
    }
}
