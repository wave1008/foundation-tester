// デモ_Android設定2.swift
// 4台並列デモ用(Android 設定アプリ・第2弾)。デモ_Android設定.swift で未使用の画面を巡回する。
// 全セレクタは 日本語||英語 の連鎖(エミュのロケール混在対応)。#id はロケール非依存。
// 戻る DSL が無いため、画面を変える scene 先頭で launchApp() し設定トップへリセットする。
// 対象外(タップ禁止): Google / 壁紙とスタイル / デジタルウェルビーイング / 緊急情報と緊急通報 —
// いずれも別パッケージが設定タスクの前面に残り、以後の launchApp 前面判定が全滅する(SafetyCenter と同型)。

import FTDSL

@TestClass(app: "com.android.settings", platform: "android")
class デモ_Android設定2 {

    @Test("ストレージの使用量とカテゴリを確認できる")
    func S0010() {
        scenario {
            scene(1, "ストレージを開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("ストレージ||Storage", maxSwipes: 12)
                    tap("ストレージ||Storage")
                }.expectation {
                    exist("#usage_summary")  // 使用量の大型表示
                    exist("空き容量を増やす||Free up space")
                }
            }
            scene(2, "カテゴリ一覧を確認しながらスクロールする") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("画像||Images")
                    exist("動画||Videos")
                }
            }
        }
    }

    @Test("システム設定の主要項目が表示される")
    func S0020() {
        scenario {
            scene(1, "システムを開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("システム||System", maxSwipes: 12)
                    tap("システム||System")
                }.expectation {
                    exist("言語と地域||Language & region")
                    exist("日付と時刻||Date & time")
                }
            }
            scene(2, "バックアップの項目まで確認する") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("バックアップ||Backup")
                }
            }
        }
    }

    @Test("モード(サイレント・おやすみ時間)を確認できる")
    func S0030() {
        scenario {
            scene(1, "モードを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("モード||Modes")
                }.expectation {
                    exist("サイレント モード||Do Not Disturb")
                    exist("おやすみ時間||Bedtime")
                }
            }
            scene(2, "独自モード作成の項目まで確認する") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("独自のモードを作成||Create your own mode")
                }
            }
        }
    }

    @Test("パスワードとアカウントの設定を確認できる")
    func S0040() {
        scenario {
            scene(1, "パスワードとアカウントを開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("パスワード、パスキー、アカウント||Passwords, passkeys & accounts", maxSwipes: 12)
                    tap("パスワード、パスキー、アカウント||Passwords, passkeys & accounts")
                }.expectation {
                    exist("優先サービス||Preferred service")
                    exist("アカウントを追加||Add account")
                }
            }
            scene(2, "自動同期のスイッチがある") {
                action {
                    swipe(.up)
                }.expectation {
                    exist(".Switch#switchWidget")
                }
            }
        }
    }

    @Test("インターネット詳細で Wi-Fi 接続を確認できる")
    func S0050() {
        scenario {
            scene(1, "ネットワークとインターネット > インターネット を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("ネットワークとインターネット||Network & internet")
                    tap("インターネット||Internet")
                }.expectation {
                    // エミュレータ既定の Wi-Fi AP
                    exist("AndroidWifi")
                }
            }
            scene(2, "一覧を上下にスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("AndroidWifi")
                }
            }
        }
    }
}
