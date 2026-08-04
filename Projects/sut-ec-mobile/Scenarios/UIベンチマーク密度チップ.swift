// UIベンチマーク密度チップ.swift
// testbase 外(開発補助画面の回帰): UIベンチマーク画面(高密度カレンダー)の年数チップ
// 全4プリセット(1/3/6/12年)で benchmark_cell_count が正しい総日数を出すことを網羅検証する。
// 遷移・日ドリルダウン・rememberSaveable 回帰は UIベンチマーク遷移.swift 側。ここは密度切替の全域網羅に限定。
//
// セル数は BASE_YEAR=2020 固定・現在時刻非依存の純関数(BenchmarkCalendarScreen.kt)。うるう年込みの
// 総日数: 1年=366 / 3年=1096 / 6年=2192 / 12年=4383(2020..2031 のうるう年は 2020/2024/2028)。
// 各 scene は「切替 action → 総日数 textIs」で差分検証(前 scene と必ず値が変わるので黙って未切替なら落ちる)。
//
// 注意(iOS の罠): 画面外(フォールド下)の day セルは accessibilityFrame が下端へ丸め込まれタップが
// 外れる。本シナリオは day タップを行わない(cell_count は画面上部の可視要素)ため iOS/Android 共に安全。
// 注意(iOS の罠2): Scaffold ルートの testTag(#screen_benchmark / #screen_benchmark_day)は iOS の
// AX ツリーに要素として現れず exist/ifCanSelect で解決できない(実行で確認)。着地判定・正規化ガードは
// leaf 要素(#benchmark_cell_count / #slot_00 / #chip_years_n)で行う。
// セレクタは iPhone 17 Pro(iOS 27.0)/ Pixel 9(Android 15)・ja_JP・ベンチマーク画面ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile")  // iOS/Android 両対応(#id は testTag→accessibilityId/resource-id で共通)
class UIベンチマークの密度チップが正しいこと {

    // 状態の正規化(各 @Test の前に毎回実行される)。launchApp は直前画面から再開するため、
    // 既知の開始点へ揃えてからテスト本体を走らせる
    func setUp() {
        launchApp()
        // launchApp が benchmark/day 画面から再開する場合に備え、タブが見える状態へ正規化。
        // Scaffold ルート testTag は AX に出ないため leaf 要素で在圏判定する。
        ifCanSelect("#slot_00") { tap("#btn_back") }              // 日詳細に居たら戻る
        ifCanSelect("#benchmark_cell_count") { tap("#btn_back") } // カレンダーに居たら戻る
    }

    // 年数は rememberSaveable で保持される。緑経路は scene 6 が 3年へ戻すが、失敗は
    // シナリオ全体を中断して scene 6 に届かないため、カレンダーに居る失敗時はここで戻す
    func tearDown() {
        ifCanSelect("#chip_years_3", waitSeconds: 1) { tap("#chip_years_3") }
    }

    @Test("全4プリセットでセル数(総日数)が正しい")
    func S0010() {
        scenario {
            scene(1, "アカウント → UIベンチマーク到達") {
                action {
                    tap("#tab_account")
                    tap("#btn_benchmark")
                }.expectation {
                    exist("#benchmark_cell_count")
                    exist("#chip_years_3")
                }
            }
            scene(2, "1年 → 366セル") {
                action {
                    tap("#chip_years_1")
                }.expectation {
                    select("#benchmark_cell_count").textIs("セル数: 366")
                }
            }
            scene(3, "3年 → 1096セル") {
                action {
                    tap("#chip_years_3")
                }.expectation {
                    select("#benchmark_cell_count").textIs("セル数: 1096")
                }
            }
            scene(4, "6年 → 2192セル") {
                action {
                    tap("#chip_years_6")
                }.expectation {
                    select("#benchmark_cell_count").textIs("セル数: 2192")
                }
            }
            scene(5, "12年 → 4383セル(最大密度)") {
                action {
                    tap("#chip_years_12")
                }.expectation {
                    select("#benchmark_cell_count").textIs("セル数: 4383")
                }
            }
            scene(6, "後始末: 既定の3年へ戻す") {
                // rememberSaveable で年数が保持されるため、他シナリオへ 12年を残さない。
                action {
                    tap("#chip_years_3")
                }.expectation {
                    select("#benchmark_cell_count").textIs("セル数: 1096")
                }
            }
        }
    }
}
