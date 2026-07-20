// お気に入り.swift
// testbase: TC-70(SC-70)登録と一覧 / TC-72(SC-72)一覧から解除。
// 商品詳細の ♡(#btn_wishlist_toggle)でお気に入り登録/解除ができ、お気に入りタブに反映されることを検証。
// ♡ はトグルでラベルが「お気に入りに追加」↔「お気に入りから削除」に切り替わる(状態依存)。
// 擬陽性対策: トグルは状態依存なので、まず「未登録」を基準化してから登録→確認→後始末で解除する。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP・修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class お気に入りを登録解除できること {

    @Test("商品をお気に入りに登録してタブで確認できる")
    func S0010() {
        scenario {
            scene(1, "対象商品を未登録状態にする(基準化)") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_home")  // launchApp の再開画面を正規化
                    wait(1)
                    tap("#product_card_fashion_5")  // おすすめ先頭カード（id 指定）→ 詳細
                    wait(1)
                    // 既に登録済みなら外して「未登録」を基準にする(トグルの擬陽性回避)
                    ifCanSelect("お気に入りから削除") { tap("#btn_wishlist_toggle") }
                    wait(1)
                }.expectation {
                    exist("お気に入りに追加")  // ♡ が未登録状態
                }
            }
            scene(2, "お気に入りに登録する") {
                action {
                    tap("#btn_wishlist_toggle")
                    wait(1)
                }.expectation {
                    exist("お気に入りから削除")  // ♡ が登録状態に変化=登録成立
                }
            }
            scene(3, "お気に入りタブに表示される") {
                action {
                    tap("#btn_back")
                    wait(1)
                    tap("#tab_wishlist")
                    wait(1)
                }.expectation {
                    exist("ミニマルデザイン腕時計")  // 登録商品が一覧にある
                }
            }
            scene(4, "後始末: お気に入りから削除して空に戻す") {
                action {
                    // 一覧の ♡(単一項目なのでラベル完全一致で一意)
                    tap(".Button=お気に入りから削除")
                    wait(1)
                }.expectation {
                    exist("お気に入りは空です")
                }
            }
        }
    }
}
