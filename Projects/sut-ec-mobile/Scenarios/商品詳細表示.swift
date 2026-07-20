// 商品詳細表示.swift
// testbase TC-30(SC-30)詳細情報表示 + TC-32(SC-32)割引表示。
// TC-30 指定 SKU:「ワイヤレスイヤホン Pro(electronics_1)」= ブランド サウンドウェーブ / ¥8,900 /
//   定価 ¥12,000 取消線 / -25% / 在庫あり / ベストセラー・Prime タグ。
// TC-32 割引率は整数除算の切り捨て(四捨五入ではない):
//   electronics_1 = (12000-8900)*100/12000 = 25.83… → -25%
//   electronics_3(メカニカルキーボード)= (15000-12500)*100/15000 = 16.67… → -16%
// セレクタは修正版ビルドで採取(#product_card_electronics_1/3, #chip_category_electronics, #text_price)。

import FTDSL

@TestClass(app: "com.sutec.mobile")  // iOS/Android 両対応(#id は testTag→resource-id/accessibilityId で共通)
class 商品詳細が表示されること {

    @Test("商品詳細に情報と割引が表示される")
    func S0010() {
        scenario {
            scene(1, "ワイヤレスイヤホン Pro の詳細を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_search")
                    tap("#chip_category_electronics")
                    tap("#product_card_electronics_1")
                }.expectation {
                    exist("ワイヤレスイヤホン Pro")  // 商品名
                    exist("サウンドウェーブ")        // ブランド
                    exist("在庫あり")
                    exist("ベストセラー")
                    exist("Prime")
                    exist("#btn_add_to_cart")
                }
            }
            scene(2, "割引価格と割引率(切り捨て)が表示される") {
                expectation {
                    exist("¥8,900")   // 割引後価格
                    exist("¥12,000")  // 定価(取消線)
                    exist("-25%")     // 25.83→切り捨て25
                }
            }
            scene(3, "別商品でも割引率は切り捨て表示される(TC-32)") {
                action {
                    tap("#btn_back")
                    tap("#product_card_electronics_3")  // メカニカルキーボード
                }.expectation {
                    exist("¥12,500")
                    exist("¥15,000")
                    exist("-16%")     // 16.67→切り捨て16(四捨五入なら17=誤り)
                }
            }
        }
    }
}
