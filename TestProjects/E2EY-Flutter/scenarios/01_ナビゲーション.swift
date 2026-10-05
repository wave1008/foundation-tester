// 01_ナビゲーション.swift
// 確かめる癖: 12 行のホーム(下の行は折り返しの下 = tap(scroll:) で届かせる)・アイコンだけの戻る(#btn_back)。
// 契約は E2EYAppCMP/docs/ui-contract.md。

import FTDSL

@TestClass
class ホームから各画面へ行って戻れること {

    @Test("12 画面を上から順に開いて戻る")
    func S0010() {
        scenario {
            scene(1, "ホームが出る") {
                condition {
                    launchApp()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(2, "入れ子スクロールへ行って戻る") {
                action {
                    tap("#nav_nested", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("入れ子スクロール")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(3, "反転チャットへ行って戻る") {
                action {
                    tap("#nav_chat", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("反転チャット")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(4, "読み込みの状態へ行って戻る") {
                action {
                    tap("#nav_loading", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("読み込みの状態")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(5, "スワイプの操作へ行って戻る") {
                action {
                    tap("#nav_swipe_actions", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("スワイプの操作")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(6, "選択モードへ行って戻る") {
                action {
                    tap("#nav_select", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("選択モード")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(7, "文中リンクへ行って戻る") {
                action {
                    tap("#nav_links", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("文中リンク")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(8, "PIN と OTPへ行って戻る") {
                action {
                    tap("#nav_pin", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("PIN と OTP")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(9, "戻るの横取りへ行って戻る") {
                action {
                    tap("#nav_back_guard", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("戻るの横取り")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(10, "引き伸ばせるシートへ行って戻る") {
                action {
                    tap("#nav_player", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("引き伸ばせるシート")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(11, "スクロールで隠れるバーへ行って戻る") {
                action {
                    tap("#nav_hide_bars", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("スクロールで隠れるバー")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(12, "折りたたみヘッダとタブへ行って戻る") {
                action {
                    tap("#nav_tab_header", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("折りたたみヘッダとタブ")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
            scene(13, "高さの揃わないグリッドへ行って戻る") {
                action {
                    tap("#nav_staggered", scroll: .down)
                }.expectation {
                    select("#txt_screen_title").textIs("高さの揃わないグリッド")
                }.action {
                    tap("#btn_back")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
        }
    }
}
