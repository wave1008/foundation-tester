// 01_ナビゲーション.swift
// 確かめる癖: ホームの12行(折り返しの下を含む)から各画面へ行けて、システムの戻る(#BackButton)で戻れる。
// 契約は E2EYAppCMP/docs/ui-contract.md、iOS の差分は E2EYAppIOS/docs/ui-contract.md。

import FTDSL

@TestClass
class ホームから各画面へ行って戻れること {

    @Test("先頭と末尾の行へ行って戻る")
    func S0010() {
        scenario {
            scene(1, "ホームが出る") {
                condition {
                    launchApp()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(2, "先頭の行から入れ子スクロールへ") {
                action {
                    tap("#nav_nested")
                }.expectation {
                    select("#txt_screen_title").textIs("入れ子スクロール")
                }
            }
            scene(3, "戻る") {
                action {
                    tap("#BackButton")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(4, "折り返しの下の末尾の行へ") {
                action {
                    tap("#nav_staggered", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("高さの揃わないグリッド")
                }
            }
            scene(5, "back で戻る") {
                action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
        }
    }

    @Test("12画面すべての見出しが契約どおり")
    func S0020() {
        scenario {
            scene(1, "各行を押して見出しを読み、戻る") {
                condition {
                    launchApp()
                }.action {
                    for (nav, title) in [
                        ("#nav_nested", "入れ子スクロール"), ("#nav_chat", "反転チャット"),
                        ("#nav_loading", "読み込みの状態"), ("#nav_swipe_actions", "スワイプの操作"),
                        ("#nav_select", "選択モード"), ("#nav_links", "文中リンク"),
                        ("#nav_pin", "PIN と OTP"), ("#nav_back_guard", "戻るの横取り"),
                        ("#nav_player", "引き伸ばせるシート"), ("#nav_hide_bars", "スクロールで隠れるバー"),
                        ("#nav_tab_header", "折りたたみヘッダとタブ"), ("#nav_staggered", "高さの揃わないグリッド"),
                    ] {
                        tap(nav, scroll: .down)
                        select("#txt_screen_title").textIs(title)
                        tap("#BackButton")
                    }
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
        }
    }
}
