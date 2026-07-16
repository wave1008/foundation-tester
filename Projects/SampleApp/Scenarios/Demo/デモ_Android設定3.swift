// デモ_Android設定3.swift
// 4台並列デモ用(Android 設定アプリ・第3弾)。デモ_Android設定.swift/2.swift で未使用の画面を巡回する。
// 全セレクタは 日本語||英語 の連鎖(エミュのロケール混在対応)。#id はロケール非依存。
// 戻る DSL が無いため、画面を変える scene 先頭で launchApp() し設定トップへリセットする。
// 対象外(タップ禁止): Google / 壁紙とスタイル / デジタルウェルビーイング / 緊急情報と緊急通報 /
// セキュリティとプライバシー(SafetyCenter)/ 開発者向けオプション — 別パッケージが前面に残り
// 以後の launchApp 前面判定が全滅する(実測: 壁紙とスタイルへの誤タップからの復旧に Navigate up 要)。
// バッテリー>バッテリー セーバー行のタップは com.android.settings をクラッシュさせる(実機確認、2026-07-16)。
// 設定 > アプリ > 既定のアプリ は「トップ画面自体」が RoleManager
// (com.google.android.permissioncontroller の DefaultAppListActivity)のため開くこと自体不可:
// 前面に残り以後の launchApp 判定が全滅する(検証 run で実測。個別行だけの罠ではない)。

import FTDSL

@TestClass(app: "com.android.settings", platform: "android")
class デモ_Android設定3 {

    @Test("アプリの一覧(すべてのアプリ)を確認できる")
    func S0010() {
        scenario {
            scene(1, "すべてのアプリを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("アプリ||Apps")
                    // 実ラベル「30 個のアプリをすべて表示」— 先頭に可変数(アプリ数)が入るため
                    // 数を含まない安定部分文字列で contains 一致させる
                    tap("アプリをすべて表示||See all")
                }.expectation {
                    // 一覧先頭付近の安定アプリ(Chrome/連絡帳は下方のためスクロールして確認する)
                    exist("カメラ||Camera")
                }
            }
            scene(2, "スクロールして Chrome を確認する") {
                action {
                    scrollTo("Chrome", maxSwipes: 12)
                }.expectation {
                    exist("Chrome")
                }
            }
            scene(3, "スクロールして一覧の最後の YouTube Music を確認する") {
                action {
                    // 対象はリスト末尾の項目に限る: scrollTo のフリングはスナップショット間で複数画面
                    // 飛ぶことがあり、中間の項目(旧: 連絡帳)は跳び越されて見つからないことがある
                    // (2026-07-16 実測)。末尾はフリングが飽和して必ず最終画面に残るため頑健。
                    // 上方向スワイプ(direction: .down)もリスト先頭で通知シェード/ホームジェスチャに
                    // 化けてアプリを離脱するため使わない
                    scrollTo("YouTube Music", maxSwipes: 12)
                }.expectation {
                    exist("YouTube Music")
                }
            }
        }
    }

    @Test("通知のサブ画面(アプリの通知・通知の履歴)を確認できる")
    func S0020() {
        scenario {
            scene(1, "アプリの通知を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("通知||Notifications")
                    tap("アプリの通知||App notifications")
                }.expectation {
                    exist("アプリの通知||App notifications")
                    exist("新しい順||Most recent")  // 実ラベルは「新しい順」(「最新」ではない)
                }
            }
            scene(2, "設定トップへ戻して通知の履歴を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("通知||Notifications")
                    tap("通知履歴||Notification history")  // 実ラベルは「通知履歴」(「の」なし)
                }.expectation {
                    exist("#main_switch_bar")
                }
            }
        }
    }

    @Test("画面のタイムアウト設定を確認できる(値は変更しない)")
    func S0030() {
        scenario {
            scene(1, "ディスプレイ > 画面のタイムアウトを開く") {
                condition {
                    launchApp()
                }.action {
                    // A15/16 実ラベルは「ディスプレイとタップ」(旧「ディスプレイ」は消滅)。
                    // 「ディスプレイ」単体はユーザー補助の要約にも部分一致し曖昧解決不能になる
                    scrollTo("ディスプレイとタップ||Display & touch", maxSwipes: 12)
                    tap("ディスプレイとタップ||Display & touch")
                    tap("画面消灯||Screen timeout")  // A15/16 実ラベル「画面消灯」(旧「画面自動消灯」は説明文にのみ残存)
                }.expectation {
                    exist("#collapsing_toolbar")
                    exist("15 秒||15 seconds")
                    exist("30 分||30 minutes")
                }
            }
            scene(2, "選択肢を上下にスクロールして眺める(選ばない)") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("1 分||1 minute")
                }
            }
        }
    }

    @Test("システムの言語設定を確認できる")
    func S0040() {
        scenario {
            scene(1, "システム > 言語と地域を開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("システム||System", maxSwipes: 12)
                    tap("システム||System")
                    // A15=言語 / A16=言語と地域(既存ファイルで確認済みの表記差)
                    tap("言語||言語と地域||Languages||Language & region")
                }.expectation {
                    exist("#collapsing_toolbar")
                    exist("システムの言語||System Languages")
                }
            }
            scene(2, "地域の項目までスクロールして確認する") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("地域||Region")
                }
            }
        }
    }

    @Test("システムのジェスチャー設定を確認できる(閲覧のみ)")
    func S0050() {
        scenario {
            scene(1, "システム > ジェスチャーを開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("システム||System", maxSwipes: 12)
                    tap("システム||System")
                    tap("ジェスチャー||Gestures")
                }.expectation {
                    exist("#collapsing_toolbar")
                    // A15 ジェスチャー画面の安定項目(旧「電源ボタンを 2 回押す/回押す」は当該画面に非存在)
                    exist("電源ボタンを長押し||Press and hold power button")
                }
            }
        }
    }

    @Test("日付と時刻の設定を確認できる(閲覧のみ・変更しない)")
    func S0060() {
        scenario {
            scene(1, "システム > 日付と時刻を開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("システム||System", maxSwipes: 12)
                    tap("システム||System")
                    tap("日付と時刻||Date & time")
                }.expectation {
                    exist("#collapsing_toolbar")
                    exist("日時を自動的に設定||Set time automatically")  // A15 実ラベル「日時を自動的に設定」
                }
            }
            scene(2, "タイムゾーンの項目までスクロールして確認する") {
                action {
                    swipe(.up)
                }.expectation {
                    exist("タイムゾーン||Time zone")
                }
            }
        }
    }
}
