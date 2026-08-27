// 06_待機とタイムアウト.swift
// fleetest 機能: 暗黙待ち(exist/textIs の既定タイムアウト再試行)と `timeout:` 引数 / notExist(未配置と
// 不在の判定)/ countIs / 相対セレクタ `基準:below(...)` `基準:above(...)` / スコープ `祖先 >> 子孫` /
// 状態フィルタ(enabled) / appIs / screenshot / waitForDisplay / verify をまとめて検証する
// (旧: 08_待機とタイムアウト の S0010 / 12_セレクタ拡張 / 21_新規コマンド の S0010)。
// #btn_delay_8 は既定5秒を超えるため timeout: を明示して通す(timeout が効いていることの証明であり、
// 「失敗させる」テストにはしない)。固定 wait() は暗黙待ちがあるため使わない。
// 旧シナリオ境界は tap("#tab_home") でホームへ戻ってから叩き直す形に置き換えてある
// (AppShell はタブ切替で子画面の State を破棄するため、state=idle 等の初期値はこれだけで戻る)。
// **S0020 は独立のまま**(#btn_delay_8 の 8 秒待ちが乗るため、統合すると1本の実行時間が伸びすぎる)。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class 待機とタイムアウトが正しく効くこと {

    @Test("暗黙待ち・notExist/countIs・相対セレクタとスコープ・状態フィルタ・appIs/screenshot/waitForDisplay/verify")
    func S0010() {
        scenario {
            scene(1, "08.S0010: 既定タイムアウト内の遅延表示は暗黙待ちで拾える") {
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
                    // (README「既知の fleetest 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
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
            scene(3, "12.S0010: notExist は未配置の要素を不在と判定し、消えるまで待つ") {
                condition {
                    tap("#tab_home")
                    tap("#nav_async")
                }.expectation {
                    notExist("#txt_delayed")
                }.action {
                    tap("#btn_delay_1")
                }.expectation {
                    exist("#txt_delayed")
                }.action {
                    tap("#btn_async_reset")
                }.expectation {
                    notExist("#txt_delayed")
                    select("#txt_delay_state").textIs("state=idle")
                }
            }
            scene(4, "countIs で同一ラベル要素の個数を数える") {
                condition {
                    tap("#btn_back")
                    tap("#nav_selector")
                }.expectation {
                    countIs(".button&&項目", 3)
                    countIs("#btn_item_1", 1)
                    countIs("存在しないラベル", 0)
                }
            }
            scene(5, "方向セレクタで同一ラベル群をアンカーで選び分ける") {
                action {
                    tap("#btn_allow:below(.button&&項目)")
                }.expectation {
                    // 縦一列なので上下で選ぶ。`許可` の下にある最初の `項目` は 1 番目(ui-contract.md の並び順)
                    select("#txt_selector_result").textIs("result=item1")
                }.action {
                    tap("#btn_selector_reset:above(.button&&項目)")
                }.expectation {
                    select("#txt_selector_result").textIs("result=item3")
                }
            }
            scene(6, "スコープ(>>)は祖先の子孫だけを対象にする") {
                condition {
                    tap("#btn_back")
                    tap("#nav_scroll")
                }.expectation {
                    // #list_rows は行を包む容器(ui-contract.md)。スコープはその子孫だけを見る
                    exist("#list_rows >> #row_02")
                    countIs("#list_rows >> #row_02", 1)
                    // スコープ外(固定ヘッダ)の要素はスコープ内からは解決できない
                    notExist("#list_rows >> #txt_row_selected")
                }
            }
            scene(7, "`&&` 合成・序数つき相対セレクタ・状態フィルタ") {
                condition {
                    tap("#btn_back")
                    tap("#nav_selector")
                }.expectation {
                    // `&&` は id と型の併用にも使える(`.button#btn_allow` と同義の一般形)
                    exist("#btn_allow&&.button")
                    countIs(".button&&項目", 3)
                }.action {
                    // 引数末尾の `&&[n]` は「その方向で近い順の n 番目」。`許可` の下に `項目` が
                    // 3 つ縦に並ぶので 2 番目は item2(並び順は ui-contract.md)
                    tap("#btn_allow:below(.button&&項目&&[2])")
                }.expectation {
                    select("#txt_selector_result").textIs("result=item2")
                }
            }
            scene(8, "状態フィルタ(enabled)を id と併用して候補を絞る") {
                condition {
                    tap("#btn_back")
                    tap("#tab_controls")
                    tapWithScrollDown("#btn_controls_reset")
                    scrollToTop()
                }.expectation {
                    // **状態フィルタは型ではなく id と併用する**: 同じ役割の要素でも型は SUT ごとに
                    // 割れる(この画面の無効ボタンは View/XML では clickable、CMP では button。
                    // ui-contract.md「型で指さない要素」)。enabled は 3 ブリッジ共通で埋まる
                    exist("#btn_always_disabled&&enabled=false")
                    exist("#btn_toggle_target&&enabled=false")
                }.action {
                    tap("#cb_agree")
                }.expectation {
                    // 同意すると条件付きボタンだけが有効化される(常時無効ボタンは不変)
                    exist("#btn_toggle_target&&enabled=true")
                    exist("#btn_always_disabled&&enabled=false")
                }
            }
            scene(9, "21.S0010: appIs・screenshot・waitForDisplay・verify が非同期表示画面で動く") {
                condition {
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
                    // Flutter は iOS/Android とも同じ bundle ID(com.ftester.e2e.flutter)を使う
                    appIs("com.ftester.e2e.flutter")
                }
            }
            scene(10, "非同期表示画面を開いてスクリーンショットを撮る") {
                action {
                    tap("#nav_async")
                    screenshot(filename: "S0010_async")
                }.expectation {
                    select("#txt_delay_state").textIs("state=idle")
                }
            }
            scene(11, "waitForDisplay で3秒後表示を待つ(暗黙待ちでなく明示の待機コマンド)") {
                action {
                    tap("#btn_delay_3")
                }.expectation {
                    // 戻り値は FTElement なのでそのままチェーンで検証できる
                    waitForDisplay("#txt_delayed", waitSeconds: 6)
                        .textIs("遅延表示 完了")
                    select("#txt_delay_state").textIs("state=done")
                }
            }
            scene(12, "verify が exist と textIs をまとめて1ステップにする") {
                expectation {
                    verify("遅延表示が完了し、状態表示も done になっていること") {
                        exist("#txt_delayed")
                        select("#txt_delay_state").textIs("state=done")
                    }
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
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の fleetest 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
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
