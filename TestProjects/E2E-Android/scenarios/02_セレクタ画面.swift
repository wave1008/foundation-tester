// 02_セレクタ画面.swift
// ftester 機能: セレクタ画面で解決できる記法をまとめて検証する
// (#id 完全一致 / ラベルの一致規則 / 型・序数・フォールバック連鎖 / OR・否定フィルタ・対称アサーション・scroll:)。
// View 系は android:id の resource-id が自動で #id になる。ComposeView(コントロール画面)の中だけは
// testTagsAsResourceId を立てないと引けない(E2EAppAndroid/docs/ui-contract.md)。
// 序数の契約(Pixel 9/Android 15 の実スナップショットで採取): `.型[n]` は「現在画面に見えている
// 同型要素をツリー順に数えた n 番目」。セレクタ画面の Button 順は 戻る(1) 許可(2) 通知を許可(3)
// 項目(4,5,6) 共通ラベル(7) 別名(8) 結果クリア(9) タブ(10-12)。よって3番目の『項目』= `.button[6]`。
// **同じアプリの中で型語彙が揃う**: View の Button も Compose の Button も型 `Button`(ブリッジが
// 役割マーカー子から復元する。docs/design.md 型語彙節)。
// 同じセレクタ画面を起点にする軽量シナリオを1 @Test の連続 scene へ統合し launchApp を1回に絞る。
// 旧シナリオ境界は tap("#tab_home") でホームへ戻ってから #nav_selector を叩き直す形に置き換えてある
// (タブ切替は container を作り直すため result="-" 等の初期値はこれだけで戻る。
// E2EAppAndroid/MainActivity.kt の switchTab/render 参照)。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class セレクタ画面の機能一式が正しく動くこと {

    @Test("#id 完全一致・ラベル一致規則・型と序数とフォールバック・OR/否定フィルタと対称アサーション")
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
            scene(12, "04.S0010: 序数・型限定 id・型限定ラベル・フォールバック連鎖と、View/Compose の型差") {
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
            scene(16, ".型&&共通ラベル は #txt_shared_label(staticText)ではなく #btn_shared_label(button)に着地") {
                action {
                    tap(".button&&共通ラベル")
                }.expectation {
                    select("#txt_selector_result").textIs("result=shared")
                }
            }
            scene(17, "コントロールタブ(ComposeView)の Compose Button も View と同じ .button で引ける") {
                condition {
                    tap("#tab_controls")
                }.expectation {
                    select("#txt_radio").textIs("plan=A")
                }.action {
                    tap("#radio_b")
                }.expectation {
                    // **途中で確定させる**: 省くと最後の plan=A が初期値のままでも通り、
                    // ラジオもリセットも空振りした場合と区別がつかない
                    select("#txt_radio").textIs("plan=B")
                }.action {
                    tap(".button&&コントロールリセット")
                }.expectation {
                    select("#txt_radio").textIs("plan=A")
                }
            }
            scene(18, "16.S0010: 和集合・フィルタ内 OR・否定フィルタ・対称アサーション・exist(scroll:)") {
                condition {
                    tap("#tab_home")
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    select("#txt_selector_result").textIs("result=-")
                }
            }
            scene(19, "`||` は候補集合の和(節ごとの件数ではなく合計)") {
                expectation {
                    // 「最初に解決した節だけを数える」旧セマンティクスなら 1 になる
                    countIs("#btn_item_1||#btn_item_2", 2)
                    // 同じ要素を指す節が並んでも 1 度だけ数える
                    countIs("#btn_item_1||#btn_item_1", 1)
                    // 解決できない節は 0 件として足される(btn_none は存在しない id)
                    countIs("#btn_none||#btn_item_3", 1)
                }
            }
            scene(20, "フィルタ内 OR `(a|b)` は `||` と同じ和集合になる") {
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
            scene(21, "否定フィルタ `!=` は候補から取り除く") {
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
            scene(22, "対称化したテキスト検証(前方一致・後方一致・不一致・非空)") {
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
            scene(23, "否定の短縮形 `!` は完全形と同じ意味") {
                condition {
                    // **クリアしてから撃つ**: 省くと下の tap の期待値が scene 21 の残り値と
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
            scene(24, "`exist(scroll:)` は画面外の要素を探索してから検証する") {
                expectation {
                    // 折り返しの下にある要素。scroll を付けない exist は現在画面しか見ない。
                    // 画面を送ってしまうのでこの @Test の最後に置く
                    exist("#txt_offscreen", scroll: .down, maxSwipes: 12)
                }.action {
                    tap("#tab_home")
                }
            }
        }
    }
}
