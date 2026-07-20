// カートの数量操作.swift
// testbase TC-41(SC-41)数量増減と再計算 / TC-42(SC-42)数量1→0で自動削除。
// 対象: product_card_fashion_5 =「ミニマルデザイン腕時計」¥18,000。空カートを基準化して検証する。
// セレクタは修正版ビルドで採取(#btn_qty_increment/#btn_qty_decrement はカート行のもの・1商品なので一意)。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class カートの数量を操作できること {

    /// カート画面で対象行を削除して空にする(基準化)
    private func emptyCart() {
        ifCanSelect("#btn_remove_fashion_5", waitSeconds: 1) { tap("#btn_remove_fashion_5") }
    }

    /// 空カートを作り、腕時計を1点だけ入れてカート画面に着地する
    private func resetAndAddOneWatch() {
        tap("#tab_cart")
        emptyCart()
        tap("#tab_home")
        tap("#product_card_fashion_5")
        tap("#btn_add_to_cart")
        tap("#btn_open_cart")
    }

    @Test("カートで数量を増やすと合計が再計算される")
    func S0010() {
        scenario {
            scene(1, "空カートに腕時計を1点追加") {
                condition {
                    launchApp()
                }.action {
                    resetAndAddOneWatch()
                }.expectation {
                    exist("合計")
                    exist("¥18,000")  // 1点=¥18,000
                }
            }
            scene(2, "数量を増やすと合計が倍になる") {
                action {
                    tap("#btn_qty_increment")  // カート行の＋
                }.expectation {
                    exist("¥36,000")  // ¥18,000 × 2 に再計算
                }
            }
            scene(3, "後始末: カートを空に戻す") {
                action {
                    tap("#btn_remove_fashion_5")
                }.expectation {
                    exist("カートは空です")
                }
            }
        }
    }

    // TC-42(SC-42)準拠: 数量1で − → 明細が自動削除される、を期待する。
    // 【現状 RED / 不具合 D-01】実装は数量1で #btn_qty_decrement が disabled で削除されない
    // (削除はゴミ箱のみ)。仕様違反のため本テストは意図的に RED。修正(1→0自動削除の実装)で緑化する。
    // scene3 の後始末は scene2 が NG でも次 scene として実行されるため残留は残さない。
    @Test("数量1から減らすとカートから削除される")
    func S0020() {
        scenario {
            scene(1, "空カートに腕時計を1点追加") {
                condition {
                    launchApp()
                }.action {
                    resetAndAddOneWatch()
                }.expectation {
                    exist("合計")
                }
            }
            scene(2, "数量1で − を押すと明細が削除される(TC-42)") {
                action {
                    tap("#btn_qty_decrement")  // 期待: 1→0 で自動削除
                }.expectation {
                    exist("カートは空です")  // 現状は削除されず RED(不具合 D-01)
                }
            }
            scene(3, "後始末: 残っていればゴミ箱で削除") {
                action {
                    ifCanSelect("#btn_remove_fashion_5", waitSeconds: 1) { tap("#btn_remove_fashion_5") }
                }.expectation {
                    exist("カートは空です")
                }
            }
        }
    }
}
