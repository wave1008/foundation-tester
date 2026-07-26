// 12_セレクタ拡張.swift
// ftester 機能: notExist / countIs / 近接セレクタ `:near(...)` / スコープ `祖先 >> 子孫`。
// **この SUT に置く意味**: セレクタ解決は a11y ツリーの形に依存するので、フレームワークが
// 変われば同じ記法でも当たり外れが変わる。記法は4フレームワーク共通で通ることを確かめる。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class セレクタ拡張が正しく解決できること {

    @Test("否定・個数・近接・スコープの各セレクタが期待どおり解決する")
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
                    textIs("#txt_delay_state", "state=idle")
                }
            }
            scene(2, "countIs で同一ラベル要素の個数を数える") {
                condition {
                    tap("#btn_back")
                    tap("#nav_selector")
                }.expectation {
                    countIs(".Button=項目", 3)
                    countIs("#btn_item_1", 1)
                    countIs("存在しないラベル", 0)
                }
            }
            scene(3, "近接セレクタで同一ラベル群をアンカーで選び分ける") {
                action {
                    tap(".Button=項目:near(#btn_allow)")
                }.expectation {
                    // `許可` に最も近い `項目` は 1 番目(ui-contract.md の並び順)
                    textIs("#txt_selector_result", "result=item1")
                }.action {
                    tap(".Button=項目:near(#btn_selector_reset)")
                }.expectation {
                    textIs("#txt_selector_result", "result=item3")
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
        }
    }
}
