// 検索と絞り込み.swift
// testbase: TC-21(SC-21)カテゴリ絞り込み。TC-20 キーワード/TC-22 価格帯/TC-23 並び替えは別シナリオで扱う。
// 検索画面のカテゴリ絞り込み(上部チップ)で結果が切り替わることを検証する。
// キーワード検索は IME 確定/submit の発火条件が不透明でフレーク源のため本シナリオでは扱わない
// (別途 UI 側の確定タイミングが固まってから)。
// カテゴリチップは #chip_category_<id>(fashion/electronics)で指す。ラベル依存を排し
// iOS/Android 共通・i18n 非依存にした(旧: ".Button=ファッション" のラベル完全一致)。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP・修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile")  // iOS/Android 両対応(#id は testTag→resource-id/accessibilityId で共通)
class 検索で絞り込めること {

    @Test("カテゴリで絞り込むと結果が切り替わる")
    func S0010() {
        scenario {
            scene(1, "検索ランディングを開く") {
                condition {
                    launchApp()
                }.action {
                    // launchApp は直前画面から再開するため、ホーム経由で検索ランディングへ正規化する
                    tap("#tab_home")
                    tap("#tab_search")
                }.expectation {
                    exist("カテゴリから探す")
                }
            }
            scene(2, "ファッションで絞り込む") {
                action {
                    tap("#chip_category_fashion")  // 上部カテゴリチップ(id 指定)
                }.expectation {
                    exist("メンズ デニムジャケット")  // ファッションの商品が出る
                }
            }
            scene(3, "家電・電化製品に切り替えると結果が変わる") {
                action {
                    tap("#chip_category_electronics")
                }.expectation {
                    exist("ワイヤレスイヤホン Pro")  // 電化製品の商品に切り替わる
                }
            }
        }
    }
}
