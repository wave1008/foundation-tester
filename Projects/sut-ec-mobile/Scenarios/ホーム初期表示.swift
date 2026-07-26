// ホーム初期表示.swift
// testbase TC-10(SC-10): ホーム初期表示。見出し/検索バー/バナー/カテゴリ/おすすめ/ベストセラーが並ぶ。
// セレクタは修正版ビルドで採取(#screen_home, #product_card_<pid>, #tab_*)。

import FTDSL

@TestClass(app: "com.sutec.mobile")  // iOS/Android 両対応(#id は testTag→resource-id/accessibilityId で共通)
class ホームが初期表示されること {

    // 状態の正規化(各 @Test の前に毎回実行される)。launchApp は直前画面から再開するため、
    // 既知の開始点へ揃えてからテスト本体を走らせる
    func setUp() {
        launchApp()
        tap("#tab_home")  // 直前画面から再開しても正規化
    }

    @Test("ホームに主要セクションが表示される")
    func S0010() {
        scenario {
            scene(1, "ホームを開く") {
                expectation {
                    exist("SUT Store")
                    // 検索バーは placeholder("商品を検索")のみ。Android は hint が label でなく
                    // placeholder に載り exist(label 一致)で拾えないため iOS 限定で確認する
                    ios { exist("商品を検索") }
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
