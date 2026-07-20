// ホーム初期表示.swift
// testbase TC-10(SC-10): ホーム初期表示。見出し/検索バー/バナー/カテゴリ/おすすめ/ベストセラーが並ぶ。
// セレクタは修正版ビルドで採取(#screen_home, #product_card_<pid>, #tab_*)。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class ホームが初期表示されること {

    @Test("ホームに主要セクションが表示される")
    func S0010() {
        scenario {
            scene(1, "ホームを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_home")  // 直前画面から再開しても正規化
                }.expectation {
                    exist("SUT Store")
                    exist("商品を検索")       // 検索バー
                    exist("今だけ全品送料無料")  // キャンペーンバナー
                    exist("カテゴリ")
                    exist("おすすめ")
                    exist("ベストセラー")
                    exist("#product_card_fashion_5")  // おすすめ商品カード
                }
            }
        }
    }
}
