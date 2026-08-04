// カートの数量操作.swift
// testbase TC-41(SC-41)数量増減と再計算 / TC-42(SC-42)数量1→0で自動削除。
// 対象: product_card_fashion_5 =「ミニマルデザイン腕時計」¥18,000。空カートを基準化して検証する。
// セレクタは修正版ビルドで採取(#btn_qty_increment/#btn_qty_decrement はカート行のもの・1商品なので一意)。

import FTDSL

@TestClass(app: "com.sutec.mobile")  // iOS/Android 両対応(#id は testTag→resource-id/accessibilityId で共通)
class カートの数量を操作できること {

    /// カート画面で対象行を削除して空にする(基準化)
    private func emptyCart() {
        ifCanSelect("#btn_remove_fashion_5", waitSeconds: 1) { tap("#btn_remove_fashion_5") }
    }

    // 2 本の @Test がどちらも「空カート + 腕時計1点」から始まるので前提整備は setUp に置く
    // (各 @Test の前に毎回実行される)。着地の確認は各シナリオの scene 1 で行う
    func setUp() {
        launchApp()
        resetAndAddOneWatch()
    }

    // カートは実行を跨いで累積するため、失敗後でも必ず空へ戻す(tearDown は失敗後でも実行される。
    // 失敗はシナリオ全体を中断するので、後始末をシナリオ内の scene に置いても実行されない)
    func tearDown() {
        ifCanSelect("#btn_back") { tap("#btn_back") }
        ifCanSelect("#tab_cart") { tap("#tab_cart") }
        emptyCart()
    }

    /// 空カートを作り、腕時計を1点だけ入れてカート画面に着地する
    private func resetAndAddOneWatch() {
        tap("#tab_cart")
        emptyCart()
        tap("#tab_home")
        tap("#product_card_fashion_5", timeout: 5)  // ホームおすすめは非同期ロード(Android cold で既定0.7sは空振り)
        tap("#btn_add_to_cart")
        tap("#btn_open_cart")
    }

    @Test("カートで数量を増やすと合計が再計算される")
    func S0010() {
        scenario {
            scene(1, "空カートに腕時計を1点追加できている(setUp の着地確認)") {
                expectation {
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
    // 失敗はシナリオ全体を中断するため、残留の後始末はシナリオ内ではなく tearDown が担う。
    @Test("数量1から減らすとカートから削除される")
    func S0020() {
        scenario {
            scene(1, "空カートに腕時計を1点追加できている(setUp の着地確認)") {
                expectation {
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
        }
    }
}
