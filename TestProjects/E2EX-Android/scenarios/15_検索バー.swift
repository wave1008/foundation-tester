// 15_検索バー.swift
// 確かめる癖: Material3 SearchBar(展開すると全画面の別レイヤに入力欄と候補が出る・候補の絞り込み・
// キーボードの検索で確定)。
// 入力欄の value は入力ではなく説明文(iOS)。以前は type の読み返しが追送を繰り返して入力が重複した
// (2026-09-28 に修正。値が動かないときは画面を OCR で見る)。その回帰テストを兼ねる

import FTDSL

@TestClass
class 検索バーで検索できること {

    @Draft("既知の制約: Android で ACTION_SET_TEXT が拒まれる入力欄がある(Material SearchView・Flutter の一部の欄)")
    @Test("入力で候補を絞り、候補を押して確定")
    func S0010() {
        scenario {
            scene(1, "開いて入力") {
                condition {
                    launchApp()
                    tap("#nav_search", scroll: .down)
                }.action {
                    tap("#field_search")
                    type("ap")
                }.expectation {
                    exist("#suggestion_apricot")
                    notExist("#suggestion_banana")
                }
            }
            scene(2, "候補を押す") {
                action {
                    tap("#suggestion_apricot")
                }.expectation {
                    select("#txt_search_result").textIs("search=apricot")
                }
            }
        }
    }

    @Draft("既知の制約: Android で ACTION_SET_TEXT が拒まれる入力欄がある(Material SearchView・Flutter の一部の欄)")
    @Test("キーボードの検索で確定")
    func S0020() {
        scenario {
            scene(1, "入力して Enter") {
                condition {
                    launchApp()
                    tap("#nav_search", scroll: .down)
                }.action {
                    tap("#field_search")
                    type("banana")
                    pressEnter()
                }.expectation {
                    select("#txt_search_result").textIs("search=banana")
                }
            }
        }
    }
}
