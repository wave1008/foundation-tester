// デモ_iOS設定3.swift
// 4台並列デモ用(iOS 設定アプリ・第3弾)。デモ_iOS設定/デモ_iOS設定2 で未使用の画面を巡回する。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP で実機確認済み。#id はロケール非依存。
// この実機では Wi-Fi/Bluetooth/モバイル通信/通知/サウンド/画面表示と明るさ/コントロールセンター/
// バッテリーはサイドバーに存在しない(シミュレータ仕様)。iCloud は未サインインで
// Apple Account サインインシートに直行するため対象外。結果、未使用画面は
// 検索(検索エンジン画面含む)/一般>トラックパッド/自動入力とパスワード/画面の取り込み/
// VPNとデバイス管理 の実在確認済み5画面のみ。
// 一般配下の各行はレイアウト直後に描画が間に合わないことがあるため scrollTo で確実に出す。

import FTDSL

@TestClass(app: "com.apple.Preferences", platform: "ios")
class デモ_iOS設定3 {

    @Test("検索の設定項目とインストール済みアプリ一覧を確認できる")
    func S0010() {
        scenario {
            scene(1, "検索を開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("#com.apple.settings.search||検索")
                    tap("#com.apple.settings.search||検索")
                }.expectation {
                    exist("#検索履歴を表示")
                    exist("#関連コンテンツを表示")
                    exist("#SEARCH_ENGINE_SETTING||検索エンジン")
                }
            }
            scene(2, "検索の項目を上下にスクロールして確認する") {
                action {
                    swipe(.up)
                    swipe(.up)
                    swipe(.down)
                    swipe(.down)
                }.expectation {
                    exist("#SEARCH_ENGINE_SETTING||検索エンジン")
                }
            }
            scene(3, "インストール済みアプリ一覧の末尾までスクロールする") {
                action {
                    scrollTo("#com.apple.MobileAddressBook||連絡先", maxSwipes: 12)
                }.expectation {
                    exist("#com.apple.MobileAddressBook||連絡先")
                }
            }
            scene(4, "設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.search||検索")
                }
            }
        }
    }

    @Test("検索エンジンの選択画面を確認できる")
    func S0020() {
        scenario {
            scene(1, "検索から検索エンジン設定を開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("#com.apple.settings.search||検索")
                    tap("#com.apple.settings.search||検索")
                    tap("#SEARCH_ENGINE_SETTING||検索エンジン")
                }.expectation {
                    exist("#Google")
                    exist("#Yahoo! JAPAN")
                }
            }
            scene(2, "候補一覧を確認する") {
                action {
                    swipe(.down)
                    swipe(.up)
                }.expectation {
                    exist("#Bing")
                    exist("#DuckDuckGo")
                    exist("#Ecosia")
                }
            }
            scene(3, "検索へ戻ってから設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                    wait(1)  // 戻りアニメの整定待ち(既存デモの流儀を踏襲)
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.search||検索")
                }
            }
        }
    }

    @Test("一般のトラックパッド設定を確認できる")
    func S0030() {
        scenario {
            scene(1, "一般 > トラックパッドを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#com.apple.settings.general||一般")
                    scrollTo("#com.apple.settings.general.pointerDevice||トラックパッド")
                    tap("#com.apple.settings.general.pointerDevice||トラックパッド")
                }.expectation {
                    exist("#trackingSpeed")
                    exist(".Switch#naturalScrolling")
                }
            }
            scene(2, "タップとセカンダリクリックの項目まで確認する") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist(".Switch#tapToClick")
                    exist(".Switch#twoFingerSecondaryClick")
                }
            }
            scene(3, "一般へ戻って設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.general||一般")
                }
            }
        }
    }

    @Test("一般の自動入力とパスワードを確認できる")
    func S0040() {
        scenario {
            scene(1, "一般 > 自動入力とパスワードを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#com.apple.settings.general||一般")
                    scrollTo("#com.apple.settings.general.autoFillAndPasswords||自動入力とパスワード")
                    tap("#com.apple.settings.general.autoFillAndPasswords||自動入力とパスワード")
                }.expectation {
                    exist(".Switch#AutoFillToggle")
                    exist(".Switch#AutoFillFromPasswordsToggle")
                }
            }
            scene(2, "確認コードの項目まで確認する") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist(".Switch#SuggestStrongPasswordsToggle")
                }
            }
            scene(3, "一般へ戻って設定トップへ戻れる") {
                action {
                    tap("#BackButton")
                    tap("#BackButton")
                }.expectation {
                    exist("#com.apple.settings.general||一般")
                }
            }
        }
    }

    @Test("一般の画面の取り込みとVPNとデバイス管理を確認できる")
    func S0050() {
        scenario {
            scene(1, "一般 > 画面の取り込みを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#com.apple.settings.general||一般")
                    scrollTo("#com.apple.settings.general.screenCapture||画面の取り込み")
                    tap("#com.apple.settings.general.screenCapture||画面の取り込み")
                }.expectation {
                    exist("フルスクリーンプレビュー")
                    exist("自動的に画像を調べる")
                }
            }
            scene(2, "一般へ戻ってVPNとデバイス管理を開く") {
                action {
                    tap("#BackButton")
                    wait(1)  // 戻りアニメの整定待ち(既存デモの流儀を踏襲)
                    scrollTo("#com.apple.settings.general.vpnAndDeviceManagement||VPNとデバイス管理")
                    tap("#com.apple.settings.general.vpnAndDeviceManagement||VPNとデバイス管理")
                }.expectation {
                    // プロファイル未導入のため画面タイトルは「デバイス管理」になる。空状態文言は label でなく id で露出する
                    exist(".NavigationBar#デバイス管理")
                    exist("#現在インストールされているプロファイルはありません。")
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
