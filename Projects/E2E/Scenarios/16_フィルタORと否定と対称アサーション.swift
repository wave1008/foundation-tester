// 16_フィルタORと否定と対称アサーション.swift
// ftester 機能: `||` の候補集合の和 / フィルタ内 OR `(a|b)` / 否定フィルタ `!=` と短縮形 `!` /
// 対称化したテキスト検証(textStartsWith / textEndsWith / textIsNot / textIsNotEmpty) /
// スクロール探索の引数 `scroll:` と Shirates 準拠のスクロールコマンド
// (scrollToTop / scrollToBottom / scrollDown(repeat:) / withScrollDown / existWithoutScroll) /
// thisIs 系 / doUntilTrue。
// いずれもホスト側(セレクタ解決・DSL)の機能なので、記法の意味そのものは
// Tests/FTDSLTests/FTSelectorTests.swift と Tests/FTCoreTests/{SelectorScopeTests,AssertKindsTests}.swift
// が固定している。この場は「実機のスナップショットで解決し、タップ・検証まで届くこと」だけを見る。
// 要素の並びと個数は E2EApp/docs/ui-contract.md(セレクタ画面)が唯一の正。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class フィルタORと否定と対称アサーションが実機で動くこと {

    @Test("和集合・フィルタ内 OR・否定フィルタ・対称アサーション・scroll 引数")
    func S0010() {
        scenario {
            scene(1, "セレクタ画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    textIs("#txt_selector_result", "result=-")
                }
            }
            scene(2, "`||` は候補集合の和(節ごとの件数ではなく合計)") {
                expectation {
                    // 「最初に解決した節だけを数える」旧セマンティクスなら 1 になる
                    countIs("#btn_item_1||#btn_item_2", 2)
                    // 同じ要素を指す節が並んでも 1 度だけ数える
                    countIs("#btn_item_1||#btn_item_1", 1)
                    // 解決できない節は 0 件として足される(btn_none は存在しない id)
                    countIs("#btn_none||#btn_item_3", 1)
                }
            }
            scene(3, "フィルタ内 OR `(a|b)` は `||` と同じ和集合になる") {
                expectation {
                    // 素の文字列は完全一致なので「通知を許可」は入らない。
                    // **ラベルで数えるときは型で絞る**: この SUT はボタンの内側にも同じラベルの
                    // Text が出るため、型を付けないと 1 ボタンにつき 2 件数える(11 と同じ規律)
                    countIs(".button&&(許可|別名ボタン)", 2)
                    countIs("(#btn_allow|#btn_alias_new)", 2)
                    countIs("(#btn_item_1|#btn_item_2)", 2)
                    // 部分一致記法とも併用できる(*許可* が 2 件、*項目* が 3 件)
                    countIs(".button&&*(許可|項目)*", 5)
                }.action {
                    // 和集合の先頭 = 節の順。1 つ目は解決できないので 2 つ目に着地する
                    tap("(#btn_none|#btn_item_2)")
                }.expectation {
                    textIs("#txt_selector_result", "result=item2")
                }
            }
            scene(4, "否定フィルタ `!=` は候補から取り除く") {
                expectation {
                    countIs(".button&&項目", 3)
                    countIs(".button&&項目&&id!=btn_item_2", 2)
                    // text の否定: 「許可」を含むが「許可」そのものではない = 通知を許可 だけ
                    countIs(".button&&*許可*&&text!=許可", 1)
                }.action {
                    // 否定は積み重ねられる(残るのは item3 だけ)
                    tap(".button&&項目&&id!=btn_item_1&&id!=btn_item_2")
                }.expectation {
                    textIs("#txt_selector_result", "result=item3")
                }
            }
            scene(5, "対称化したテキスト検証(前方一致・後方一致・不一致・非空)") {
                expectation {
                    textStartsWith("#txt_selector_result", "result=")
                    textEndsWith("#txt_selector_result", "item3")
                    textIsNot("#txt_selector_result", "result=-")
                    textIsNotEmpty("#txt_selector_result")
                    // exist の戻り値にも同じ検証をチェーンできる
                    exist("#txt_selector_result")
                        .textStartsWith("result=")
                        .textEndsWith("item3")
                }
            }
            scene(6, "`exist(scroll:)` は画面外の要素を探索してから検証する") {
                expectation {
                    // 折り返しの下にある要素。scroll を付けない exist は現在画面しか見ない(07 参照)
                    exist("#txt_offscreen", scroll: .down, maxSwipes: 12)
                }
            }
            scene(7, "`tap(scroll:)` は探索してからタップする(scrollTo を前置するのと同じ)") {
                condition {
                    // 下部タブは固定なのでスクロール位置に関わらず押せる
                    tap("#tab_home")
                    tap("#nav_scroll")
                }.action {
                    // 狙うのは一覧末尾(07 と同じ `#row_40`)。中間行も通るようになったが
                    // (docs/verification.md「スクロールした直後のタップ」)、Android 側に
                    // 変更前からある行リサイクル起因の不安定さが残るため末尾を使う
                    tap("#row_40", scroll: .down, maxSwipes: 15)
                }.expectation {
                    // #txt_row_selected は固定ヘッダなのでスクロール後も見える(07 と同じ理由)。
                    // **スクロール後に元の位置へ戻って検証しない**(戻す向きの操作は不安定)
                    textIs("#txt_row_selected", "selected=row_40")
                }
            }
            scene(8, "`scrollToBottom` / `scrollToTop` は端まで送る") {
                action {
                    scrollToTop(maxSwipes: 20)
                }.expectation {
                    // 端まで戻っていれば先頭行が**探索なしで**見えている
                    existWithoutScroll("#row_01")
                }
            }
            scene(9, "`scrollDown(repeat:)` は指定回数ぶん1画面ずつ送る") {
                action {
                    scrollDown(repeat: 2)
                }.expectation {
                    // 遅延生成の一覧なので、送った先では先頭行がツリーから消える
                    notExist("#row_01", timeout: 2)
                }
            }
            scene(10, "`withScrollDown { }` はブロック内をスクロール探索にする") {
                condition {
                    scrollToTop(maxSwipes: 20)
                }.action {
                    withScrollDown {
                        // 明示の scroll: を書かなくても探索される(狙いは 07 と同じ末尾行)
                        tap("#row_40")
                        // 固定ヘッダは現在画面にあるので、探索を打ち消して確認する
                        existWithoutScroll("#txt_row_selected")
                    }
                }.expectation {
                    textIs("#txt_row_selected", "selected=row_40")
                }
            }
            scene(11, "否定の短縮形 `!` は完全形と同じ意味") {
                condition {
                    tap("#tab_home")
                    tap("#nav_selector")
                }.expectation {
                    countIs(".button&&項目&&!#btn_item_2", 2)
                    countIs(".button&&*許可*&&!許可", 1)
                }.action {
                    tap(".button&&項目&&!#btn_item_1&&!#btn_item_2")
                }.expectation {
                    textIs("#txt_selector_result", "result=item3")
                }
            }
            scene(12, "`thisIs` 系は画面に触れない値を検証する") {
                expectation {
                    // API 応答・計算結果をそのまま検証できる(素の値に直接生える)
                    let 合計 = "合計 1,200円"
                    合計.thisContains("1,200")
                    合計.thisStartsWith("合計")
                    合計.thisEndsWithNot("ドル")
                    (10 * 3).thisIs(30)
                    "2026/07/27".thisMatchesDateFormat("yyyy/MM/dd")
                }
            }
            scene(13, "doUntilTrue は条件が成立するまで繰り返す") {
                action {
                    // アプリ・外部の状態待ち用。画面要素の出現待ちは各コマンドの timeout: を使う
                    var 試行回数 = 0
                    doUntilTrue("3 回目で成立する", waitSeconds: 5, intervalSeconds: 0.1) {
                        試行回数 += 1
                        return 試行回数 >= 3
                    }
                }
            }
        }
    }
}
