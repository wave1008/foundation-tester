// 数量とカート小計.swift
// 商品詳細の数量ステッパー(#btn_qty_increment)で個数を増やして追加すると、
// カートの小計/合計に単価×個数が反映されることを検証する。
// 擬陽性対策: カートを空にしてから 3 個(¥18,000×3=¥54,000)追加し、¥54,000 の出現で確認。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP・修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class 数量を指定してカートに追加できること {

    /// カート画面で全行を削除して空にする(基準化)。削除は各行同一 id=btn_remove_item で複数行だと
    /// 曖昧なため先頭行を型+順番 .Button[2] で狙う。空カートでは「合計」が無く空振りして無害。
    private func emptyCart() {
        ifCanSelect("合計", waitSeconds: 1) { tap(".Button[2]") }
        ifCanSelect("合計", waitSeconds: 1) { tap(".Button[2]") }
        ifCanSelect("合計", waitSeconds: 1) { tap(".Button[2]") }
        ifCanSelect("合計", waitSeconds: 1) { tap(".Button[2]") }
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
                    tap(".Button=ミニマルデザイン腕時計")
                    wait(1)
                    tap("#btn_qty_increment")  // 1 → 2
                    wait(1)
                    tap("#btn_qty_increment")  // 2 → 3
                    wait(1)
                    tap(".Button=カートに追加")
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
                    tap("#btn_remove_item")  // 単一行なので id で一意
                    wait(1)
                }.expectation {
                    exist("カートは空です")
                }
            }
        }
    }
}
