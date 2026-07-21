// UIベンチマーク遷移.swift
// testbase 外(開発補助画面の回帰): UIベンチマーク画面(高密度カレンダー年表示)の
// 到達 → 日タップで日詳細へ遷移 → 戻る、を検証する。密度チップの網羅は
// UIベンチマーク密度チップ.swift 側。ここは遷移導線に専念する。
// セレクタは iPhone 17 Pro(iOS 27.0)/Pixel 9(Android 15)・ja_JP・
// feat/ui-benchmark-calendar ビルドで採取。
//
// 設計上の注意(実測で確定した堅牢化):
// - 特定日の日付タイトル(例 "2020年1月15日")は検証しない。day セルは約17-46pxと極小で、
//   ドライバのタップが隣接セルへズレて着弾する(iOS=off-fold の accessibilityFrame クランプ、
//   Android=小セルの中心タップズレ)。どのセルに当たっても日詳細へは遷移するので、
//   遷移の成立は日詳細固有の #slot_00(0時スロット)で確認する。
// - calendar 側(1096ノード超)の #btn_back は検証しない。巨大 a11y ツリーの照会が
//   Android で既定 timeout を超えるため(重量級画面がドライバを追い込む=この画面の目的)。
//   戻る導線は小さい日詳細ツリー上の #btn_back で検証する。

import FTDSL

@TestClass(app: "com.sutec.mobile")  // iOS/Android 両対応(#id は testTag→resource-id/accessibilityId で共通)
class UIベンチマークを操作できること {

    @Test("日タップで日詳細へ遷移でき戻れる")
    func S0010() {
        scenario {
            scene(1, "アカウント → UIベンチマーク到達・3年に基準化") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_account")
                    tap("#btn_benchmark")
                    // 直前の実行が別年数で残っていても 3年へ基準化する(resume 時の擬陽性回避)。
                    tap("#chip_years_3")
                }.expectation {
                    textIs("#benchmark_cell_count", "セル数: 1096")  // 3年ぶんの総日数
                    exist("#chip_years_3")
                }
            }
            scene(2, "日セルタップで日詳細へ遷移") {
                action {
                    // 初期ビューポート内の 1月中旬セル。どの日に着弾しても日詳細へ遷移する。
                    tap("#day_2020_01_15", timeout: 10)
                }.expectation {
                    exist("#slot_00", timeout: 10)  // 日詳細固有の 0時スロット = 遷移成立の証跡
                    exist("#btn_back")              // 小ツリーの詳細画面なら btn_back は確実に取れる
                }
            }
            scene(3, "戻るでカレンダーへ復帰") {
                action {
                    tap("#btn_back")
                }.expectation {
                    textIs("#benchmark_cell_count", "セル数: 1096")
                    exist("#chip_years_3")
                }
            }
        }
    }
}
