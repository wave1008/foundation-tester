// デモ_iOS設定2.swift
// 4台並列デモ用(iOS 設定アプリ・第2弾)。デモ_iOS設定.swift で未使用の画面を巡回する。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP で実機確認済み。#id はロケール非依存。
// 「アクションボタン」画面は SwiftUI のランダム id のみでアンカー不可のため対象外。

import FTDSL

@TestClass(app: "com.apple.Preferences", platform: "ios")
class デモ_iOS設定2 {

    @Test("プライバシーとセキュリティの主要項目が表示される")
    func S0010() {
        scenario {
            scene(1, "プライバシーとセキュリティを開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("#com.apple.settings.privacyAndSecurity||プライバシーとセキュリティ")
                    tap("#com.apple.settings.privacyAndSecurity||プライバシーとセキュリティ")
                }.expectation {
                    exist("#LOCATION||位置情報サービス")
                    exist("#USER_TRACKING||トラッキング")
                }
            }
            scene(2, "一覧を上下にスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.up)
                    swipe(.down)
                    swipe(.down)
                }.expectation {
                    exist("#LOCATION||位置情報サービス")
                }
            }
            scene(3, "設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.privacyAndSecurity||プライバシーとセキュリティ")
                }
            }
        }
    }

    @Test("スクリーンタイムの管理項目が表示される")
    func S0020() {
        scenario {
            scene(1, "スクリーンタイムを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#com.apple.settings.screenTime||スクリーンタイム")
                }.expectation {
                    exist("#ScreenTime.AppsAndWebsitesRow")
                    exist("#schedule-navigation-row")
                }
            }
            scene(2, "常に許可の項目まで確認する") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#alwaysAllowedRow")
                }
            }
            scene(3, "設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.screenTime||スクリーンタイム")
                }
            }
        }
    }

    @Test("アプリ一覧と Game Center を確認できる")
    func S0030() {
        scenario {
            scene(1, "アプリを開く") {
                condition {
                    launchApp()
                }.action {
                    // label フォールバック不可: 「アプリ」は「ホーム画面とアプリライブラリ」に部分一致で誤タップする
                    scrollTo("#com.apple.settings.apps")
                    tap("#com.apple.settings.apps")
                }.expectation {
                    exist("#com.apple.Settings.Apps.DefaultApps||デフォルトのアプリ")
                }
            }
            scene(2, "アプリ一覧をスクロールして Fitness を確認する") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#com.apple.Fitness||Fitness")
                }
            }
            scene(3, "設定トップへ戻って Game Center を開く") {
                action {
                    tap("#BackButton")
                    scrollTo("#com.apple.settings.gameCenter||Game Center")
                    tap("#com.apple.settings.gameCenter||Game Center")
                }.expectation {
                    // サインイン状態は個体差があるため exist のみ
                    exist(".Switch#SignIn||.Switch=Game Center")
                }
            }
            scene(4, "設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.gameCenter||Game Center")
                }
            }
        }
    }

    @Test("スタンバイと Siri の設定画面を確認できる")
    func S0040() {
        scenario {
            scene(1, "スタンバイを開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("#com.apple.settings.standBy||スタンバイ")
                    tap("#com.apple.settings.standBy||スタンバイ")
                }.expectation {
                    exist(".Switch#AMBIENT_MODE_ENABLED")
                    exist("#ALWAYS_ON_DISPLAY_OPTIONS||画面表示")
                }
            }
            scene(2, "設定トップへ戻って Siri を開く") {
                action {
                    tap("#BackButton")
                    wait(1)  // 戻りアニメの整定待ち(デモ_iOS設定.S0030 と同パターンの予防)
                    tap("#com.apple.settings.siri||Siri")
                }.expectation {
                    exist(".NavigationBar#Siri")
                }
            }
            scene(3, "設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.siri||Siri")
                }
            }
        }
    }

    @Test("一般のキーボードと言語と地域を確認できる")
    func S0050() {
        scenario {
            scene(1, "一般 > キーボード を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#com.apple.settings.general||一般")
                    scrollTo("#com.apple.settings.general.keyboard||キーボード")
                    tap("#com.apple.settings.general.keyboard||キーボード")
                }.expectation {
                    exist("#KEYBOARDS||キーボード")
                    exist("ハードウェアキーボード")
                }
            }
            scene(2, "一般へ戻って 言語と地域 を開く") {
                action {
                    tap("#BackButton")
                    scrollTo("#com.apple.settings.general.languageAndRegion||言語と地域")
                    tap("#com.apple.settings.general.languageAndRegion||言語と地域")
                }.expectation {
                    exist("#ja-JP||日本語")
                    exist("#ADD_PREFERRED_LANGUAGE||言語を追加…")
                }
            }
            scene(3, "設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.general||一般")
                }
            }
        }
    }

    @Test("一般のフォントと辞書を確認できる")
    func S0060() {
        scenario {
            scene(1, "一般 > フォント を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#com.apple.settings.general||一般")
                    scrollTo("#com.apple.settings.general.fonts||フォント")
                    wait(1)  // スクロールのバウンス整定待ち(整定前 tap は隣接行に流れる)
                    tap("#com.apple.settings.general.fonts||フォント")
                }.expectation {
                    exist(".NavigationBar#フォント")  // 遷移完了の速いアンカー(過渡期の空振り対策)
                    exist("システムフォント||マイフォント")
                }
            }
            scene(2, "一般へ戻って 辞書 を開く") {
                action {
                    tap("#BackButton")
                    scrollTo("#com.apple.settings.general.dictionary||辞書")
                    tap("#com.apple.settings.general.dictionary||辞書")
                }.expectation {
                    exist("スーパー大辞林")
                }
            }
            scene(3, "設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.general||一般")
                }
            }
        }
    }
}
