// 数量とカート小計.swift
// testbase: TC-33(SC-33)数量指定でカート追加(数量3→カートに数量3で反映)。
// 商品詳細の数量ステッパー(#btn_qty_increment)で個数を増やして追加すると、
// カートの小計/合計に単価×個数が反映されることを検証する。
// 擬陽性対策: カートを空にしてから 3 個(¥18,000×3=¥54,000)追加し、¥54,000 の出現で確認。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP・修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class 数量を指定してカートに追加できること {

    /// 対象商品(fashion_5)の行を削除して空にする(基準化)。各行の削除ボタンは id=btn_remove_<productId> で一意。
    /// 空カートなら空振りして無害。本スイートはこの1商品のみ扱う。
    private func emptyCart() {
        ifCanSelect("#btn_remove_fashion_5", waitSeconds: 1) { tap("#btn_remove_fashion_5") }
    }

    @Test("数量を3にして追加すると小計に反映される")
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
            scene(2, "詳細で数量を3にしてカートに追加する") {
                action {
                    tap("#tab_home")
                    wait(1)
                    tap("#product_card_fashion_5")
                    wait(1)
                    tap("#btn_qty_increment")  // 1 → 2
                    wait(1)
                    tap("#btn_qty_increment")  // 2 → 3
                    wait(1)
                    tap("#btn_add_to_cart")
                    wait(1)
                    tap("#btn_open_cart")
                    wait(1)
                }.expectation {
                    exist("合計")
                    exist("¥54,000")  // ¥18,000 × 3(空基準なのでこの額=数量反映の証拠)
                }
            }
            scene(3, "後始末: カートを空に戻す") {
                action {
                    tap("#btn_remove_fashion_5")  // 行ごとに id=btn_remove_<productId>
                    wait(1)
                }.expectation {
                    exist("カートは空です")
                }
            }
        }
    }
}
