// ナビゲーション戻る.swift
// testbase TC-121(SC-121): 非タブ画面(商品詳細)では下タブが隠れ、TopBar の戻るで前画面へ復帰する。
// (下タブの非表示は exist で否定できないため、戻るで前画面へ戻れることを検証する)
// セレクタは修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class 詳細から戻れること {

    @Test("商品詳細から戻るでホームへ復帰する")
    func S0010() {
        scenario {
            scene(1, "ホームから商品詳細へ") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_home")
                    wait(1)
                    tap("#product_card_fashion_5")
                }.expectation {
                    exist("#btn_back")        // 詳細の戻るボタン
                    exist("#btn_add_to_cart")
                }
            }
            scene(2, "戻るでホームへ復帰") {
                action {
                    tap("#btn_back")
                }.expectation {
                    exist("SUT Store")
                    exist("#tab_home")  // 下タブが再表示
                }
            }
        }
    }
}
