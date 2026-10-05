// 01_ナビゲーション.swift
// 確かめる癖: 12 行のホーム(下の行は折り返しの下 = スクロール探索で届かせる)・システムの戻る(back)・
// Toolbar のアイコンだけの戻る(id を付けられない。contentDescription「戻る」で指す)。
// 契約は E2EYAppCMP/docs/ui-contract.md、この SUT の差分は E2EYAppAndroid/docs/ui-contract.md。

import FTDSL

@TestClass
class ナビゲーションが正しく働くこと {

    @Test("ホームから 12 画面へ行って戻れる")
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
                    back()
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
                    back()
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
                    back()
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
                    back()
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
                    back()
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
                    back()
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
                    back()
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
                    back()
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
                    back()
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
                    back()
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
                    back()
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
                    back()
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
        }
    }

    @Test("アイコンだけの戻るをラベルで押して戻る")
    func S0020() {
        scenario {
            scene(1, "反転チャットへ") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_chat")
                }.expectation {
                    select("#txt_screen_title").textIs("反転チャット")
                }
            }
            scene(2, "Toolbar の戻るは #btn_back を持てないので contentDescription で指す") {
                action {
                    tap("戻る")
                }.expectation {
                    select("#txt_screen_title").textIs("E2EY ホーム")
                }
            }
        }
    }
}
