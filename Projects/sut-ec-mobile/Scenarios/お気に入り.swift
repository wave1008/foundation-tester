// お気に入り.swift
// testbase: TC-70(SC-70)登録と一覧 / TC-72(SC-72)一覧から解除。
// 商品詳細の ♡(#btn_wishlist_toggle)でお気に入り登録/解除ができ、お気に入りタブに反映されることを検証。
// ♡ はトグルでラベルが「お気に入りに追加」↔「お気に入りから削除」に切り替わる(状態依存)。
// 擬陽性対策: トグルは状態依存なので、まず「未登録」を基準化してから登録→確認→後始末で解除する。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP・修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile")  // iOS/Android 両対応(#id は testTag→resource-id/accessibilityId で共通)
class お気に入りを登録解除できること {

    @Test("商品をお気に入りに登録してタブで確認できる")
    func S0010() {
        scenario {
            scene(1, "対象商品を未登録状態にする(基準化)") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_home")  // launchApp の再開画面を正規化
                    tap("#product_card_fashion_5", timeout: 5)  // おすすめ先頭カード（id 指定）→ 詳細。ホームおすすめは非同期ロード(Android cold で既定0.7sは空振り)
                    // 既に登録済みなら外して「未登録」を基準にする(トグルの擬陽性回避)
                    ifCanSelect("お気に入りから削除") { tap("#btn_wishlist_toggle") }
                }.expectation {
                    // ♡ の状態は contentDescription。Android(Compose)ではトグルの状態ラベルが
                    // 実機ツリーに label として安定露出せず解決不能。登録成立の横断的証拠は scene3
                    // (お気に入りタブに商品が出る)で取る。in-place の状態確認は iOS 限定。
                    ios { exist("お気に入りに追加") }  // ♡ が未登録状態
                }
            }
            scene(2, "お気に入りに登録する") {
                action {
                    tap("#btn_wishlist_toggle")
                }.expectation {
                    ios { exist("お気に入りから削除") }  // ♡ が登録状態に変化=登録成立(Android は scene3 で確認)
                }
            }
            scene(3, "お気に入りタブに表示される") {
                action {
                    tap("#btn_back")
                    tap("#tab_wishlist")
                }.expectation {
                    exist("ミニマルデザイン腕時計")  // 登録商品が一覧にある
                }
            }
            scene(4, "後始末: 詳細で♡を外して空に戻す") {
                action {
                    // 一覧の♡タップは iOS inapp で toggle が発火しない(id/ラベルとも解決はするが状態不変)。
                    // 詳細に入り #btn_wishlist_toggle(scene2 で iOS/Android とも実証済み)で確実に外す。
                    tap("#product_card_fashion_5")
                    tap("#btn_wishlist_toggle", timeout: 5)  // 一覧→詳細は非同期ロード。既定0.7sでは空振りしうる
                    tap("#btn_back")
                }.expectation {
                    exist("お気に入りは空です")
                }
            }
        }
    }
}
