// タブナビゲーション.swift
// 下部タブが各セクションへ正しく着地する回帰テスト。
// かつて「ホーム/検索タブがカートを開く(タブスタック汚染)」不具合があり修正済み。
// 特に scene7 は旧バグの発火条件(詳細→追加→🛒→カートで [Home,Detail,Cart] を作った後の
// ホームタブ操作)を再現し、ホームへ着地することを確認する = 退行の番人。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP・修正版ビルドで採取。前提: お気に入りが空。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class タブが正しく遷移すること {

    /// 対象商品(fashion_5)の行を削除して空にする(前回残留の基準化)。各行の削除ボタンは
    /// id=btn_remove_<productId> で一意。空カートなら空振りして無害。本シナリオはこの1商品のみ扱う。
    private func emptyCart() {
        ifCanSelect("#btn_remove_fashion_5", waitSeconds: 1) { tap("#btn_remove_fashion_5") }
    }

    @Test("下部タブが各セクションへ正しく着地する")
    func S0010() {
        scenario {
            scene(1, "基準: カートを空にする") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_cart")
                    wait(1)
                    emptyCart()
                }.expectation {
                    exist("カートは空です")
                }
            }
            scene(2, "ホームタブ → ホーム") {
                action {
                    tap("#tab_home")
                    wait(1)
                }.expectation {
                    exist("SUT Store")
                    exist("おすすめ")
                }
            }
            scene(3, "検索タブ → 検索") {
                action {
                    tap("#tab_search")
                    wait(1)
                }.expectation {
                    exist("カテゴリから探す")
                }
            }
            scene(4, "お気に入りタブ → お気に入り") {
                action {
                    tap("#tab_wishlist")
                    wait(1)
                }.expectation {
                    exist("お気に入りは空です")
                }
            }
            scene(5, "アカウントタブ → アカウント") {
                action {
                    tap("#tab_account")
                    wait(1)
                }.expectation {
                    exist("ログイン / 登録")
                }
            }
            scene(6, "カートタブ → カート(空)") {
                action {
                    tap("#tab_cart")
                    wait(1)
                }.expectation {
                    exist("カートは空です")
                }
            }
            scene(7, "汚染トリガ後もホームタブが正常(回帰)") {
                action {
                    // [Home, Detail, Cart] のスタックを作る(旧バグの発火条件)
                    tap("#tab_home")
                    wait(1)
                    tap("#product_card_fashion_5")
                    wait(1)
                    tap("#btn_add_to_cart")
                    wait(1)
                    tap("#btn_open_cart")
                    wait(1)
                    // 旧バグではここでカートが復元されて残留した。修正版はホームへ着地する
                    tap("#tab_home")
                    wait(1)
                }.expectation {
                    exist("SUT Store")
                    exist("おすすめ")
                }
            }
            scene(8, "後始末: カートを空に戻す") {
                action {
                    tap("#tab_cart")
                    wait(1)
                    tap("#btn_remove_fashion_5")  // 行ごとに id=btn_remove_<productId>
                    wait(1)
                }.expectation {
                    exist("カートは空です")
                }
            }
        }
    }
}
