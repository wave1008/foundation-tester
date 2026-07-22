// 08_待機とタイムアウト.swift
// ftester 機能: 暗黙待ち(exist/textIs の既定タイムアウト再試行)と `timeout:` 引数の検証。
// #btn_delay_8 は既定5秒を超えるため timeout: を明示して通す(timeout が効いていることの証明であり、
// 「失敗させる」テストにはしない)。固定 wait() は暗黙待ちがあるため使わない。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class 待機とタイムアウトが正しく効くこと {

    @Test("既定タイムアウト内の遅延表示は暗黙待ちで拾える")
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
                    // 既定(true)だと occlusion-guard が FM 視覚照合を呼び、Flutter の小さな
                    // テキスト領域を「覆われている」と誤判定して落ちることがある
                    // (実際には完全に見えている。2026-07-23 実測)。可視性の検証は 01 が行う。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_async")
                }.expectation {
                    textIs("#txt_delay_state", "state=idle")
                }
            }
            scene(2, "1秒後表示は既定タイムアウト内に暗黙待ちで検出される") {
                action {
                    tap("#btn_delay_1")
                }.expectation {
                    exist("#txt_delayed")
                    textIs("#txt_delay_state", "state=done")
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
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // 既定(true)だと occlusion-guard が FM 視覚照合を呼び、Flutter の小さな
                    // テキスト領域を「覆われている」と誤判定して落ちることがある
                    // (実際には完全に見えている。2026-07-23 実測)。可視性の検証は 01 が行う。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_async")
                    tap("#btn_async_reset")
                }.expectation {
                    textIs("#txt_delay_state", "state=idle")
                }
            }
            scene(2, "3秒後表示は timeout: 6 を明示して待つ") {
                action {
                    tap("#btn_delay_3")
                }.expectation {
                    exist("#txt_delayed", timeout: 6)
                    textIs("#txt_delay_state", "state=done")
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
                    textIs("#txt_delay_state", "state=done")
                }
            }
        }
    }
}
