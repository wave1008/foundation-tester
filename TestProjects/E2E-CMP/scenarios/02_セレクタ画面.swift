// 02_セレクタ画面.swift
// ftester 機能: セレクタ画面で解決できる記法をまとめて検証する
// (#id 完全一致 / ラベルの一致規則 / 型・序数・フォールバック連鎖 / OR・否定フィルタ・対称アサーション・
// scroll: / thisIs 系 / doUntilTrue / 型付きセレクタ(Sel)のフォールバック・型限定ラベル・相対セレクタ)。
// 同じ画面を起点にする軽量シナリオを1 @Test の連続 scene へ統合し launchApp を1回に絞る。
// 旧シナリオ境界は tap("#tab_home") でホームへ戻ってから #nav_selector を叩き直す形に置き換えてある
// (App() はタブ/子画面切替で remember 状態を破棄するため、result=- 等の初期値はこれだけで戻る)。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class セレクタ画面の機能一式が正しく動くこと {

    @Test("#id 完全一致・ラベル一致規則・型と序数とフォールバック・OR/否定フィルタと対称アサーション・Sel版")
    func S0010() {
        scenario {
            scene(1, "02.S0010: #id セレクタでタップし結果が echo される") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(2, "#btn_allow を id 指定でタップ") {
                action {
                    tap("#btn_allow")
                }.expectation {
                    select("#txt_selector_result").textIs("result=allow")
                }
            }
            scene(3, "#btn_shared_label を id 指定でタップ") {
                action {
                    tap("#btn_shared_label")
                }.expectation {
                    select("#txt_selector_result").textIs("result=shared")
                }
            }
            scene(4, "#btn_selector_reset で結果をクリア") {
                action {
                    tap("#btn_selector_reset")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(5, "03.S0010: 素の文字列は完全一致・部分一致は記法で明示したときだけ") {
                condition {
                    tap("#tab_home")
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(6, "「通知を許可」は完全一致するラベルでそのままタップされる") {
                action {
                    tap("通知を許可")
                }.expectation {
                    select("#txt_selector_result").textIs("result=allow_notification")
                }
            }
            scene(7, "結果をクリア") {
                action {
                    tap("#btn_selector_reset")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(8, "「許可」は #btn_allow(完全一致)が選ばれる(「通知を許可」には当たらない)") {
                action {
                    tap("許可")
                }.expectation {
                    select("#txt_selector_result").textIs("result=allow")
                }
            }
            scene(9, "結果をクリア") {
                action {
                    tap("#btn_selector_reset")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(10, "`*知を許*` と書いたときだけ部分一致で「通知を許可」を掴む") {
                action {
                    tap("*知を許*")
                }.expectation {
                    select("#txt_selector_result").textIs("result=allow_notification")
                }
            }
            scene(11, "同じ文字列を素で書くと**どの要素にも当たらない**(部分一致は暗黙には起きない)") {
                expectation {
                    // 直前の scene 10 が「*付きなら当たる」ことを示しているので、
                    // ここが空振りなのは綴り誤りではなく完全一致契約そのものの確認になる
                    notExist("知を許")
                }
            }
            scene(12, "04.S0010: 序数・型限定 id・型限定ラベル・フォールバック連鎖が同じ画面で解決できる") {
                condition {
                    tap("#tab_home")
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(13, ".button[6] で3番目の『項目』(#btn_item_3)に着地") {
                action {
                    tap(".button[6]")
                }.expectation {
                    select("#txt_selector_result").textIs("result=item3")
                }
            }
            scene(14, ".型#id で #btn_allow に着地") {
                action {
                    tap(".button#btn_allow")
                }.expectation {
                    select("#txt_selector_result").textIs("result=allow")
                }
            }
            scene(15, "btn_alias_old(存在しない) || btn_alias_new(実在) → 2つ目で解決") {
                action {
                    tap("#btn_alias_old||#btn_alias_new")
                }.expectation {
                    select("#txt_selector_result").textIs("result=alias")
                }
            }
            scene(16, ".型&&共通ラベル は #txt_shared_label(Text)ではなく #btn_shared_label(button)に着地") {
                action {
                    tap(".button&&共通ラベル")
                }.expectation {
                    select("#txt_selector_result").textIs("result=shared")
                }
            }
            scene(17, "16.S0010: 和集合・フィルタ内 OR・否定フィルタ・対称アサーション・exist(scroll:)") {
                condition {
                    tap("#tab_home")
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(18, "`||` は候補集合の和(節ごとの件数ではなく合計)") {
                expectation {
                    // 「最初に解決した節だけを数える」旧セマンティクスなら 1 になる
                    countIs("#btn_item_1||#btn_item_2", 2)
                    // 同じ要素を指す節が並んでも 1 度だけ数える
                    countIs("#btn_item_1||#btn_item_1", 1)
                    // 解決できない節は 0 件として足される(btn_none は存在しない id)
                    countIs("#btn_none||#btn_item_3", 1)
                }
            }
            scene(19, "フィルタ内 OR `(a|b)` は `||` と同じ和集合になる") {
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
                    select("#txt_selector_result").textIs("result=item2")
                }
            }
            scene(20, "否定フィルタ `!=` は候補から取り除く") {
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
            scene(21, "対称化したテキスト検証(前方一致・後方一致・不一致・非空)") {
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
            scene(22, "否定の短縮形 `!` は完全形と同じ意味") {
                condition {
                    // **クリアしてから撃つ**: 省くと下の tap の期待値が scene 20 の残り値と
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
            scene(23, "`exist(scroll:)` は画面外の要素を探索してから検証する") {
                expectation {
                    // 折り返しの下にある要素。scroll を付けない exist は現在画面しか見ない(07 参照)。
                    // 画面を送ってしまうのでこの @Test の最後に置く
                    exist("#txt_offscreen", scroll: .down, maxSwipes: 12)
                }
            }
            scene(24, "`thisIs` 系は画面に触れない値を検証する") {
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
            scene(25, "doUntilTrue は条件が成立するまで繰り返す") {
                action {
                    // アプリ・外部の状態待ち用。画面要素の出現待ちは各コマンドの timeout: を使う
                    var 試行回数 = 0
                    doUntilTrue("3 回目で成立する", waitSeconds: 5, intervalSeconds: 0.1) {
                        試行回数 += 1
                        return 試行回数 >= 3
                    }
                }
            }
            scene(26, "15.S0010: フォールバック・型限定ラベル・相対セレクタ") {
                condition {
                    tap(.id("tab_home"))
                }.action {
                    tap(.id("nav_selector"))                       // #nav_selector
                }.expectation {
                    select(.id("txt_selector_result")).textIs("result=-")  // #txt_selector_result
                }
            }
            scene(27, "型限定ラベルの個数と || フォールバック") {
                expectation {
                    countIs(.type(.button).text("項目"), 3)          // .button&&項目
                }.action {
                    // 1つ目は存在しない id。2つ目で解決する
                    tap(.id("btn_alias_old").or(.id("btn_alias_new")))  // #btn_alias_old||#btn_alias_new
                }.expectation {
                    select(.id("txt_selector_result")).textIs("result=alias")
                }
            }
            scene(28, "相対セレクタ(基準が先・近い順の2番目)") {
                action {
                    // #btn_allow:below(.button&&項目&&[2]) と同じ構造(序数は ordinal に正規化される)
                    tap(.id("btn_allow").below(matching: .type(.button).text("項目"), nth: 2))
                }.expectation {
                    select(.id("txt_selector_result")).textIs("result=item2")
                }.action {
                    tap("#tab_home")
                }
            }
        }
    }
}
