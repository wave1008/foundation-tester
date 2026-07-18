// デモ_Android禁止画面復旧.swift
// 「禁止画面」(別パッケージが設定タスクの前面に居座り、以後の launchApp 前面判定を壊す画面)を
// あえて踏み、ブリッジの自己復旧(handleLaunch のタイムアウト時 前面掃除+再試行、design.md §8.7)で
// 設定へ復帰できることを検証する回帰テスト。旧 v6 ブリッジでは scene(3) の launchApp が全滅していた。
// 注意: 復旧確認のため意図的に禁止画面へ遷移する特別なテスト。通常のデモ/シナリオではこれらの画面へ
//       遷移しないこと(他の設定シナリオ冒頭コメント参照)。
// 対象は同一タスク居住を実測済みの「セキュリティとプライバシー」(SafetyCenter=permissioncontroller)。
// 壁紙とスタイル等は別タスクで開き復旧枝を踏まない(通常 launch で戻れる)ため対象にしない。
// エミュ1(Android 16/ja)・エミュ2(Android 15/en)両対応のため全セレクタは 日本語||英語。

import FTDSL

@TestClass(app: "com.android.settings", platform: "android")
class デモ_Android禁止画面復旧 {

    @Test("禁止画面(セキュリティとプライバシー=SafetyCenter)を踏んでも launchApp が自己復旧する")
    func S0010() {
        scenario {
            scene(1, "設定トップを開く") {
                condition {
                    launchApp()
                }.expectation {
                    exist("ネットワークとインターネット||Network & internet")
                }
            }
            scene(2, "別パッケージ画面(セキュリティとプライバシー)へ意図的に遷移する") {
                action {
                    scrollTo("セキュリティとプライバシー||Security & privacy", maxSwipes: 12)
                    tap("セキュリティとプライバシー||Security & privacy")
                }.expectation {
                    // SafetyCenter(別パッケージ)のタイトル。設定タスクの前面が別パッケージへ移った証拠
                    exist(".Other=セキュリティとプライバシー||.Other=Security & privacy")
                }
            }
            scene(3, "launchApp で設定へ復帰する(旧 v6 は全滅・v7 は自己復旧)") {
                condition {
                    // 復旧枝: 前面が別パッケージのままだと launchApp は前面判定タイムアウト後に
                    // 前面を force-stop+HOME して再試行する。10数秒かかる(BridgeClient session=45s 内)
                    launchApp()
                }.expectation {
                    exist("ネットワークとインターネット||Network & internet")
                }
            }
        }
    }
}
