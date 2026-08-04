// 16_フィルタORと否定と対称アサーション.swift
// ftester 機能: `||` の候補集合の和 / フィルタ内 OR `(a|b)` / 否定フィルタ `!=` と短縮形 `!` /
// 対称化したテキスト検証(textStartsWith / textEndsWith / textIsNot / textIsNotEmpty) /
// スクロール探索の引数 `scroll:` と Shirates 準拠のスクロールコマンド
// (scrollToTop / scrollToBottom / scrollDown(repeat:) / withScrollDown / existWithoutScroll)。
// CMP 版の thisIs 系・doUntilTrue はデバイスに触れないホスト側機能で、
// CMP 版とユニットテストがすでに固定済みのためこの SUT には移植しない。
// いずれもホスト側(セレクタ解決・DSL)の機能なので、記法の意味そのものは
// Tests/FTDSLTests/FTSelectorTests.swift と Tests/FTCoreTests/{SelectorScopeTests,AssertKindsTests}.swift
// が固定している。この場は「実機のスナップショットで解決し、タップ・検証まで届くこと」だけを見る。
// 要素の並びと個数は E2EApp/docs/ui-contract.md(セレクタ画面)が唯一の正。
// **@Test は3本に分ける**(セレクタ系 / スクロールコマンド / 探索を伴うスクロール)。1本に畳むと
// 31.8s かかり、8 レーンあってもこの1本がスイート全体の壁時計(33s)を決めていた
// (2026-08-01 実測。レーン追加では縮まない = docs/performance-tuning.md §3.6)。
// 分割の粒度は他の3 SUT と揃えてある。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class フィルタORと否定と対称アサーションが実機で動くこと {

    @Test("和集合・フィルタ内 OR・否定フィルタ・対称アサーション・exist(scroll:)")
    func S0010() {
        scenario {
            scene(1, "セレクタ画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
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
                    // この SUT(View/XML の Button)は内部に別要素の Text を持たないため型を外しても
                    // 件数は変わらないが、CMP 版(Button 内 Text が二重に載る)との記法統一のため
                    // 型限定はそのまま残す
                    countIs(".button&&(許可|別名ボタン)", 2)
                    countIs("(#btn_allow|#btn_alias_new)", 2)
                    countIs("(#btn_item_1|#btn_item_2)", 2)
                    // 部分一致記法とも併用できる(*許可* が 2 件、*項目* が 3 件)
                    countIs(".button&&*(許可|項目)*", 5)
                }.action {
                    // 和集合の先頭 = 節の順。1 つ目は解決できないので 2 つ目に着地する
                    tap("(#btn_none|#btn_item_2)")
                }.expectation {
                    select("#txt_selector_result").textIs("result=item2")
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
                    select("#txt_selector_result").textIs("result=item3")
                }
            }
            scene(5, "対称化したテキスト検証(前方一致・後方一致・不一致・非空)") {
                expectation {
                    select("#txt_selector_result").textStartsWith("result=")
                    select("#txt_selector_result").textEndsWith("item3")
                    select("#txt_selector_result").textIsNot("result=-")
                    select("#txt_selector_result").textIsNotEmpty()
                    // exist の戻り値にも同じ検証をチェーンできる
                    exist("#txt_selector_result")
                        .textStartsWith("result=")
                        .textEndsWith("item3")
                }
            }
            scene(6, "否定の短縮形 `!` は完全形と同じ意味") {
                condition {
                    // **クリアしてから撃つ**: 省くと下の tap の期待値が scene 4 の残り値と
                    // 同じになり、タップが空振りしても気付けない。クリアが効いたことも
                    // 見る(効いていなければ同じ穴が開く)
                    tap("#btn_selector_reset")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                    countIs(".button&&項目&&!#btn_item_2", 2)
                    countIs(".button&&*許可*&&!許可", 1)
                }.action {
                    tap(".button&&項目&&!#btn_item_1&&!#btn_item_2")
                }.expectation {
                    select("#txt_selector_result").textIs("result=item3")
                }
            }
            scene(7, "`exist(scroll:)` は画面外の要素を探索してから検証する") {
                expectation {
                    // 折り返しの下にある要素。scroll を付けない exist は現在画面しか見ない(07 参照)。
                    // 画面を送ってしまうのでこの @Test の最後に置く
                    exist("#txt_offscreen", scroll: .down, maxSwipes: 12)
                }
            }
        }
    }

    @Test("Shirates 準拠のスクロールコマンドと tap(scroll:)")
    func S0020() {
        scenario {
            scene(1, "`tap(scroll:)` は探索してからタップする(scrollTo を前置するのと同じ)") {
                condition {
                    launchApp()
                    tap("#nav_scroll")
                }.action {
                    // 狙うのは一覧末尾(07 と同じ `#row_40`)。中間行も通るようになったが
                    // (docs/verification.md「スクロールした直後のタップ」)、この SUT
                    // (RecyclerView)は行リサイクル起因の不安定さが残るため末尾を使う
                    tap("#row_40", scroll: .down, maxSwipes: 15)
                }.expectation {
                    // #txt_row_selected は固定ヘッダなのでスクロール後も見える(07 と同じ理由)。
                    // **スクロール後に元の位置へ戻って検証しない**(戻す向きの操作は不安定)
                    select("#txt_row_selected").textIs("selected=row_40")
                }
            }
            scene(2, "`scrollToBottom` は端まで送る") {
                action {
                    scrollToBottom(maxSwipes: 20)
                }.expectation {
                    // 端まで送っていれば末尾行が**探索なしで**見えている
                    existWithoutScroll("#row_40")
                }
            }
            scene(3, "`scrollToTop` は端まで送る") {
                action {
                    scrollToTop(maxSwipes: 20)
                }.expectation {
                    // 端まで戻っていれば先頭行が**探索なしで**見えている
                    existWithoutScroll("#row_01")
                }
            }
        }
    }

    @Test("scrollDown(repeat:) と withScrollDown")
    func S0030() {
        scenario {
            scene(1, "`scrollDown(repeat:)` は指定回数ぶん1画面ずつ送る") {
                condition {
                    launchApp()
                    tap("#nav_scroll")
                }.action {
                    scrollDown(repeat: 2)
                }.expectation {
                    // 遅延生成の一覧なので、送った先では先頭行がツリーから消える
                    notExist("#row_01", timeout: 2)
                }
            }
            scene(2, "`withScrollDown { }` はブロック内をスクロール探索にする") {
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
                    select("#txt_row_selected").textIs("selected=row_40")
                }
            }
        }
    }
}
