// 01_ナビゲーション.swift
// 確かめる癖: ホームの 12 行(小さい画面では折り返しの下)から各画面へ行って戻れる。
// native-stack の戻るボタンはネイティブ描画で #btn_back を通せないので、戻りは back()。
// 契約は E2EYAppCMP/docs/ui-contract.md。

import FTDSL

@TestClass
class ホームから各画面へ行って戻れること {

    @Test("12 画面へ順に行って戻る")
    func S0010() {
        scenario {
            scene(1, "ホームが出る") {
                condition {
                    launchApp()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(2, "入れ子スクロール へ行って戻る") {
                action {
                    tap("#nav_nested", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("入れ子スクロール")
                }.action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(3, "反転チャット へ行って戻る") {
                action {
                    tap("#nav_chat", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("反転チャット")
                }.action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(4, "読み込みの状態 へ行って戻る") {
                action {
                    tap("#nav_loading", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("読み込みの状態")
                }.action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(5, "スワイプの操作 へ行って戻る") {
                action {
                    tap("#nav_swipe_actions", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("スワイプの操作")
                }.action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(6, "選択モード へ行って戻る") {
                action {
                    tap("#nav_select", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("選択モード")
                }.action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(7, "文中リンク へ行って戻る") {
                action {
                    tap("#nav_links", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("文中リンク")
                }.action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(8, "PIN と OTP へ行って戻る") {
                action {
                    tap("#nav_pin", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("PIN と OTP")
                }.action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(9, "戻るの横取り へ行って戻る") {
                action {
                    tap("#nav_back_guard", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("戻るの横取り")
                }.action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(10, "引き伸ばせるシート へ行って戻る") {
                action {
                    tap("#nav_player", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("引き伸ばせるシート")
                }.action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(11, "スクロールで隠れるバー へ行って戻る") {
                action {
                    tap("#nav_hide_bars", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("スクロールで隠れるバー")
                }.action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(12, "折りたたみヘッダとタブ へ行って戻る") {
                action {
                    tap("#nav_tab_header", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("折りたたみヘッダとタブ")
                }.action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(13, "高さの揃わないグリッド へ行って戻る") {
                action {
                    tap("#nav_staggered", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("高さの揃わないグリッド")
                }.action {
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
        }
    }
}
