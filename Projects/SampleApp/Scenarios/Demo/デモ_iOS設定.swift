// デモ_iOS設定.swift
// 4台並列デモ用(iOS 設定アプリ)。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP で実機確認済み。#id はロケール非依存。
// 画面単位ではなく関連画面をまとめた粒度で構成(1関数=複数画面の巡回)。scene 数は 20 未満に収める。
// 画面間の戻りは #BackButton(設定は階層ナビ)。scrollTo の direction 既定 .up=下方向へ送る、.down=上(先頭)へ戻す。

import FTDSL

@TestClass(app: "com.apple.Preferences", platform: "ios")
class デモ_iOS設定 {

    @Test("表示と外観の設定(外観モード・アクセシビリティ)を確認できる")
    func S0010() {
        scenario {
            scene(1, "外観モード画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#com.apple.settings.appearance||外観||Appearance")
                }.expectation {
                    exist("外観モード||Appearance")
                    exist(".Switch=自動||.Switch=Automatic")
                }
            }
            scene(2, "ダークにしてからライトへ戻す") {
                action {
                    tap("ダーク||Dark")
                    tap("ライト||Light")
                }.expectation {
                    exist("ダーク||Dark")
                    exist("ライト||Light")
                }
            }
            scene(3, "設定トップへ戻ってアクセシビリティを開く") {
                action {
                    tap("#BackButton")
                    tap("#com.apple.settings.accessibility||アクセシビリティ||Accessibility")
                }.expectation {
                    exist("#DISPLAY_AND_TEXT||画面表示とテキストサイズ")
                    exist("#MOTION_TITLE||動作")
                    exist("#SPEECH_TITLE||読み上げコンテンツ")
                }
            }
            scene(4, "アクセシビリティ一覧を上下にスクロールする") {
                action {
                    swipe(.up)
                    swipe(.up)
                    swipe(.down)
                    swipe(.down)
                }.expectation {
                    exist("#HOVERTEXT_TITLE||ホバーテキスト")
                }
            }
            scene(5, "設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.accessibility||アクセシビリティ||Accessibility")
                }
            }
        }
    }

    @Test("システムとデバイス情報(情報・デベロッパ)を確認できる")
    func S0020() {
        scenario {
            scene(1, "一般 > 情報 でバージョンと機種を確認") {
                condition {
                    launchApp()
                }.action {
                    tap("#com.apple.settings.general||一般||General")
                    tap("#com.apple.settings.general.about||情報||About")
                }.expectation {
                    exist("#SW_VERSION_SPECIFIER")   // iOSバージョン行
                    exist("#ProductModelName")       // 機種名行
                    exist("#SerialNumber")
                }
            }
            scene(2, "情報画面を上下にスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#NAME_CELL_ID")
                }
            }
            scene(3, "設定トップへ戻ってデベロッパへスクロールして開く") {
                action {
                    tap("#BackButton")
                    tap("#BackButton")
                    scrollTo("#com.apple.settings.developer||デベロッパ||Developer")
                    tap("#com.apple.settings.developer||デベロッパ||Developer")
                }.expectation {
                    exist("デベロッパ||Developer")
                }
            }
            scene(4, "Photos セクションまでスクロールする") {
                action {
                    scrollTo(".Switch#PHOTOS_UPLOAD_DEVELOPER_MODE||.Switch=Resource Upload Test Mode", maxSwipes: 12)
                }.expectation {
                    // ON/OFF は個体差があるため exist のみ(valueIs にするとデバイス状態依存になる)
                    exist(".Switch#PHOTOS_UPLOAD_DEVELOPER_MODE||.Switch=Resource Upload Test Mode")
                }
            }
            scene(5, "設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.developer||デベロッパ||Developer")
                }
            }
        }
    }

    @Test("メディアとホーム画面の設定(カメラ・ホーム画面)を確認できる")
    func S0030() {
        scenario {
            scene(1, "カメラ設定を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#com.apple.settings.camera||カメラ||Camera")
                }.expectation {
                    exist("#SMART_STYLES||フォトグラフスタイル")
                    exist("#CameraVideoSettingsList||ビデオ撮影")
                }
            }
            scene(2, "カメラ一覧を上下にスクロールする") {
                action {
                    swipe(.up)
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#SMART_STYLES||フォトグラフスタイル")
                }
            }
            scene(3, "設定トップへ戻ってホーム画面とアプリライブラリを開く") {
                action {
                    tap("#BackButton")
                    tap("#com.apple.settings.homeScreen||ホーム画面とアプリライブラリ")
                }.expectation {
                    exist("#APP_DOWNLOADS_HOME_SCREEN||ホーム画面に追加")
                    exist(".Switch#SHOW_SPOTLIGHT||.Switch=ホーム画面に表示")
                }
            }
            scene(4, "設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.homeScreen||ホーム画面とアプリライブラリ")
                }
            }
        }
    }

    @Test("設定トップを縦にスクロールして各セクションを辿れる")
    func S0040() {
        scenario {
            scene(1, "下端付近(デベロッパ)までスクロールする") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("#com.apple.settings.developer||デベロッパ||Developer", maxSwipes: 15)
                }.expectation {
                    exist("#com.apple.settings.developer||デベロッパ||Developer")
                }
            }
            scene(2, "中間(アクセシビリティ)まで戻る") {
                action {
                    scrollTo("#com.apple.settings.accessibility||アクセシビリティ||Accessibility", direction: .down, maxSwipes: 15)
                }.expectation {
                    exist("#com.apple.settings.accessibility||アクセシビリティ||Accessibility")
                }
            }
            scene(3, "先頭(一般)まで戻る") {
                action {
                    scrollTo("#com.apple.settings.general||一般||General", direction: .down, maxSwipes: 15)
                }.expectation {
                    exist("#com.apple.settings.general||一般||General")
                }
            }
            scene(4, "上下スワイプを繰り返して先頭に戻す") {
                action {
                    swipe(.up)
                    swipe(.up)
                    swipe(.down)
                    swipe(.down)
                }.expectation {
                    exist("#com.apple.settings.general||一般||General")
                }
            }
        }
    }

    // アプリ切り替えデモ: 設定 ⇔ サンプルアプリ。SampleApp は実行プロファイル(app: sampleapp)が全台に導入済み。
    // 切替は launchApp(別bundle) / home() / appSwitcher()。戻り先の既定 bundle は @TestClass の設定アプリ。
    @Test("設定アプリとサンプルアプリを行き来できる")
    func S0050() {
        scenario {
            scene(1, "設定アプリを起動する") {
                condition {
                    launchApp()
                }.expectation {
                    exist("#com.apple.settings.general||一般||General")
                }
            }
            scene(2, "サンプルアプリへ切り替える") {
                action {
                    launchApp("com.example.sampleapp")
                    wait(1)  // 起動アニメーション整定待ち
                }.expectation {
                    // 初回はログイン画面、ログイン済みならホーム画面。どちらでも通す
                    exist("#email||#welcome_text||ようこそ||ログイン")
                }
            }
            scene(3, "ホーム経由でアプリスイッチャーを開く") {
                action {
                    home()
                    appSwitcher()
                }
            }
            scene(4, "設定アプリへ戻る") {
                action {
                    launchApp()
                }.expectation {
                    exist("#com.apple.settings.general||一般||General")
                }
            }
        }
    }
}
