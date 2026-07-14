// デモ_iOS設定.swift
// 4台並列デモ用(iOS 設定アプリ)。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP で実機確認済み。#id はロケール非依存。

import FTDSL

@TestClass(app: "com.apple.Preferences", platform: "ios")
class デモ_iOS設定 {

    @Test("一般 > 情報 でデバイス情報を確認できる")
    func S0010() {
        scenario {
            scene(1, "情報画面を開いてバージョンと機種を確認") {
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
            scene(2, "情報画面をスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#NAME_CELL_ID")
                }
            }
            scene(3, "設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.general||一般||General")
                }
            }
        }
    }

    @Test("外観モードをダーク⇔ライトに切り替えられる")
    func S0020() {
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
            scene(3, "設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.appearance||外観||Appearance")
                }
            }
        }
    }

    @Test("アクセシビリティ設定の主要項目が表示される")
    func S0030() {
        scenario {
            scene(1, "アクセシビリティ画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#com.apple.settings.accessibility||アクセシビリティ||Accessibility")
                }.expectation {
                    exist("#DISPLAY_AND_TEXT||画面表示とテキストサイズ")
                    exist("#MOTION_TITLE||動作")
                    exist("#SPEECH_TITLE||読み上げコンテンツ")
                }
            }
            scene(2, "一覧をスクロールして戻る") {
                action {
                    swipe(.up)
                    swipe(.up)
                    swipe(.down)
                    swipe(.down)
                }.expectation {
                    exist("#HOVERTEXT_TITLE||ホバーテキスト")
                }
            }
        }
    }

    @Test("デベロッパ設定を開いて項目を確認できる")
    func S0040() {
        scenario {
            scene(1, "設定トップをスクロールしてデベロッパを開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("#com.apple.settings.developer||デベロッパ||Developer")
                    tap("#com.apple.settings.developer||デベロッパ||Developer")
                }.expectation {
                    exist("デベロッパ||Developer")
                }
            }
            scene(2, "Photos セクションまでスクロールする") {
                action {
                    scrollTo(".Switch#PHOTOS_UPLOAD_DEVELOPER_MODE||.Switch=Resource Upload Test Mode", maxSwipes: 12)
                }.expectation {
                    // ON/OFF は個体差があるため exist のみ(valueIs にするとデバイス状態依存になる)
                    exist(".Switch#PHOTOS_UPLOAD_DEVELOPER_MODE||.Switch=Resource Upload Test Mode")
                }
            }
        }
    }

    @Test("カメラ設定の撮影項目が表示される")
    func S0050() {
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
            scene(2, "一覧をスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#SMART_STYLES||フォトグラフスタイル")
                }
            }
        }
    }

    @Test("ホーム画面とアプリライブラリの設定が表示される")
    func S0060() {
        scenario {
            scene(1, "ホーム画面とアプリライブラリを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#com.apple.settings.homeScreen||ホーム画面とアプリライブラリ")
                }.expectation {
                    exist("#APP_DOWNLOADS_HOME_SCREEN||ホーム画面に追加")
                    exist(".Switch#SHOW_SPOTLIGHT||.Switch=ホーム画面に表示")
                }
            }
            scene(2, "設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.homeScreen||ホーム画面とアプリライブラリ")
                }
            }
        }
    }
}
