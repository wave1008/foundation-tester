// 16_フィルタORと否定と対称アサーション.swift
// ftester 機能: `||` の候補集合の和 / フィルタ内 OR `(a|b)` / 否定フィルタ `!=` と短縮形 `!` /
// 対称化したテキスト検証(textStartsWith / textEndsWith / textIsNot / textIsNotEmpty) /
// スクロール探索の引数 `scroll:` と Shirates 準拠のスクロールコマンド
// (scrollToTop / scrollToBottom / scrollDown(repeat:) / withScrollDown / existWithoutScroll)。
// いずれもホスト側(セレクタ解決・DSL)の機能なので、記法の意味そのものは
// Tests/FTDSLTests/FTSelectorTests.swift と Tests/FTCoreTests/{SelectorScopeTests,AssertKindsTests}.swift
// が固定している。この場は「実機のスナップショットで解決し、タップ・検証まで届くこと」だけを見る。
// 要素の並びと個数は E2EApp/docs/ui-contract.md(セレクタ画面)が唯一の正。
// CMP 版(Projects/E2E/Scenarios/16_フィルタORと否定と対称アサーション.swift)の移植。
// **thisIs 系(CMP 版 scene 12)と doUntilTrue(CMP 版 scene 13)は移植しない**
// (デバイスに触れないホスト側機能で CMP 版とユニットテストが固定済み)。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class フィルタORと否定と対称アサーションが実機で動くこと {

    @Test("和集合・フィルタ内 OR・否定フィルタ・対称アサーション・scroll 引数")
    func S0010() {
        scenario {
            scene(1, "セレクタ画面を開く") {
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
                    // **`.button` はここでは重複排除のためではない**(CMP と異なる): Flutter は
                    // ボタンとラベルを MergeSemantics で1ノードに畳む(widgets.dart tagged())ため
                    // 二重に数えない。他画面の同名要素との取り違え防止として型を付けておく
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
                    // 折り返しの下にある要素。scroll を付けない exist は現在画面しか見ない
                    // (07_スクロール.swift 参照)
                    exist("#txt_offscreen", scroll: .down, maxSwipes: 12)
                }
            }
            scene(7, "`tap(scroll:)` は探索してからタップする(scrollTo を前置するのと同じ)") {
                condition {
                    // 下部タブは固定なのでスクロール位置に関わらず押せる
                    tap("#tab_home")
                    tap("#nav_scroll")
                }.action {
                    // 狙うのは一覧末尾(07_スクロール.swift と同じ #row_40)。tap(scroll:) は
                    // 内部で scrollTo と同じ探索(runScrollSearch)を使うため、07 で実測した
                    // 「末尾行が下端をわずかに覗いただけで解決しタップが空振りする」問題が
                    // ここにも及ぶ可能性がある(未検証)。Android 側は ListView.builder の
                    // 遅延ビルド由来の不安定さが残るため末尾を使う
                    tap("#row_40", scroll: .down, maxSwipes: 15)
                }.expectation {
                    // #txt_row_selected は固定ヘッダなのでスクロール後も見える(07 と同じ理由)。
                    // **スクロール後に元の位置へ戻って検証しない**(戻す向きの操作は不安定)
                    textIs("#txt_row_selected", "selected=row_40")
                }
            }
            scene(8, "`scrollToBottom` は端まで送る") {
                action {
                    scrollToBottom(maxSwipes: 20)
                }.expectation {
                    // 端まで送られていれば最終行が探索なしで見えている
                    existWithoutScroll("#row_40")
                }
            }
            scene(9, "`scrollToTop` は端まで送る") {
                action {
                    scrollToTop(maxSwipes: 20)
                }.expectation {
                    // 端まで戻っていれば先頭行が探索なしで見えている
                    existWithoutScroll("#row_01")
                }
            }
            scene(10, "`scrollDown(repeat:)` は指定回数ぶん1画面ずつ送る") {
                action {
                    scrollDown(repeat: 2)
                }.expectation {
                    // 遅延生成の一覧なので、送った先では先頭行がツリーから消える
                    notExist("#row_01", timeout: 2)
                }
            }
            scene(11, "`withScrollDown { }` はブロック内をスクロール探索にする") {
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
            scene(12, "否定の短縮形 `!` は完全形と同じ意味") {
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
        }
    }
}
