// デモ_Android設定4.swift
// 4台並列デモ用(Android 設定アプリ・第4弾)。
// 旧版は未検証のサブ画面ラベル(表示サイズとテキスト/データ使用量/標準のアプリ/バッテリーセーバー/
// テキストと表示)と .Switch#switchWidget を判定にしており実機で全滅した。
// 当て推量をやめ、デモ_Android設定.swift/設定2.swift で実証済みのトップレベルカテゴリ+
// #collapsing_toolbar(全サブ画面共通の安定アンカー)のみで構成し直す。
// 戻る DSL が無いため、画面を変える scene 先頭で launchApp() し設定トップへリセットする。
// 対象外(タップ禁止): Google / 壁紙とスタイル / デジタルウェルビーイング / 緊急情報と緊急通報 /
// セキュリティとプライバシー — 別パッケージが前面に残り以後の launchApp 前面判定が全滅する。

import FTDSL

@TestClass(app: "com.android.settings", platform: "android")
class デモ_Android設定4 {

    @Test("接続設定の画面を確認できる")
    func S0010() {
        scenario {
            scene(1, "接続設定を開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("接続設定||Connected devices", maxSwipes: 12)
                    tap("接続設定||Connected devices")
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
            scene(2, "一覧を上下にスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
        }
    }

    @Test("ディスプレイの画面を確認できる")
    func S0020() {
        scenario {
            scene(1, "ディスプレイを開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("ディスプレイ||Display", maxSwipes: 12)
                    tap("ディスプレイ||Display")
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
            scene(2, "一覧を上下にスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
        }
    }

    @Test("通知の画面を確認できる")
    func S0030() {
        scenario {
            scene(1, "通知を開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("通知||Notifications", maxSwipes: 12)
                    tap("通知||Notifications")
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
            scene(2, "一覧を上下にスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
        }
    }

    @Test("音とバイブレーションの画面を確認できる")
    func S0040() {
        scenario {
            scene(1, "音とバイブレーションを開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("音とバイブレーション||Sound & vibration", maxSwipes: 12)
                    tap("音とバイブレーション||Sound & vibration")
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
            scene(2, "一覧を上下にスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
        }
    }

    @Test("バッテリーの画面を確認できる")
    func S0050() {
        scenario {
            scene(1, "バッテリーを開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("バッテリー||Battery", maxSwipes: 12)
                    tap("バッテリー||Battery")
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
            scene(2, "一覧を上下にスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
        }
    }

    @Test("位置情報の画面を確認できる")
    func S0060() {
        scenario {
            scene(1, "位置情報を開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("位置情報||Location", maxSwipes: 12)
                    tap("位置情報||Location")
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
            scene(2, "一覧を上下にスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
        }
    }
}
