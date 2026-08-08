// 12_セレクタ拡張.swift
// ftester 機能: notExist / countIs / 相対セレクタ `基準:below(...)` `基準:above(...)` / スコープ `祖先 >> 子孫`。
// **この SUT に置く意味**: セレクタ解決は a11y ツリーの形に依存するので、フレームワークが
// 変われば同じ記法でも当たり外れが変わる。記法は4フレームワーク共通で通ることを確かめる。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class セレクタ拡張が正しく解決できること {

    @Test("否定・個数・方向・スコープの各セレクタが期待どおり解決する")
    func S0010() {
        scenario {
            scene(1, "notExist は未配置の要素を不在と判定し、消えるまで待つ") {
                condition {
                    launchApp()
                    tap("#nav_async")
                }.expectation {
                    // 待機中はツリーに未配置(非表示ではない)
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
            scene(2, "countIs で同一ラベル要素の個数を数える") {
                condition {
                    tap("#btn_back")
                    tap("#nav_selector")
                }.expectation {
                    countIs(".button&&項目", 3)
                    countIs("#btn_item_1", 1)
                    countIs("存在しないラベル", 0)
                }
            }
            scene(3, "方向セレクタで同一ラベル群をアンカーで選び分ける") {
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
            scene(4, "スコープ(>>)は祖先の子孫だけを対象にする") {
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
            scene(5, "`&&` 合成・序数つき相対セレクタ・状態フィルタ") {
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
            scene(6, "状態フィルタ(enabled)を id と併用して候補を絞る") {
                condition {
                    tap("#btn_back")
                    tap("#tab_controls")
                    tap("#btn_controls_reset")
                }.expectation {
                    // **状態フィルタは型ではなく id と併用する**: 同じ役割の要素でも型は SUT ごとに
                    // 割れる(ui-contract.md「型で指さない要素」)。enabled は 3 ブリッジ共通で埋まる
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
        }
    }
}
