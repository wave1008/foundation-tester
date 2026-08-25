// 02_セレクタ画面.swift
// fleetest 機能: セレクタ画面で解決できる記法をまとめて検証する
// (#id 完全一致 / ラベルの一致規則 / 型・序数・フォールバック連鎖 / OR・否定フィルタ・対称アサーション・scroll:)。
// 同じ画面を起点にする軽量シナリオを1 @Test の連続 scene へ統合し launchApp を1回に絞る
// (E2E-iOS 02_セレクタ画面.swift の移植。旧 02/03/04/16.S0010 の統合)。
// RN の `testID` が iOS = accessibilityIdentifier / Android = resource-id にマップされるため、
// #id が両 OS 共通で引ける。**型語彙は予測**: ボタンは `.button` に正規化されるはず(04 参照。
// 未検証だが型セレクタを使ってよいのは Button だけというネイティブ側の運用を保険として引き継ぐ)。
// 旧シナリオ境界は tap("#tab_home") でホームへ戻ってから #nav_selector を叩き直す形に置き換えてある
// (AppShell はタブ切替で homeChild を null に戻し子画面をアンマウントするため、result="-" 等の
// 初期値はこれだけで戻る)。**境界でも起動直後の同期用 exist("#txt_home_marker", requireVisible: false)
// は維持する**(02.S0010 冒頭の注記どおり、ポインタ入力取りこぼし対策の1往復)。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class セレクタ画面の機能一式が正しく動くこと {

    @Test("#id 完全一致・ラベル一致規則・型と序数とフォールバック連鎖・OR/否定フィルタと対称アサーション・exist(scroll:)")
    func S0010() {
        scenario {
            scene(1, "02.S0010: #id セレクタでタップし結果が echo される") {
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
                    // (README「既知の fleetest 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
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
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
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
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
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
            scene(16, ".型&&共通ラベル は #txt_shared_label(staticText 予測)ではなく #btn_shared_label(button 予測)に着地") {
                action {
                    tap(".button&&共通ラベル")
                }.expectation {
                    select("#txt_selector_result").textIs("result=shared")
                }
            }
            scene(17, "16.S0010: 和集合・フィルタ内 OR・否定フィルタ・対称アサーション・exist(scroll:)") {
                condition {
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
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
                    // **ラベルで数えるときは型で絞る**(ボタンと内側のラベルは別要素として両方
                    // 載り得るため。docs/commands.md の一般規律。11 と同じ規律)
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
