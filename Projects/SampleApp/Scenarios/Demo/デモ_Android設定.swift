// デモ_Android設定.swift
// 4台並列デモ用(Android 設定アプリ)。
// エミュ1(Pixel 9/Android 16)=日本語、エミュ2(Pixel 9/Android 15)=英語のため全セレクタは 日本語||英語 の連鎖。
// サブ画面のタイトルは .Other#collapsing_toolbar のラベルで確認できる(全サブ画面共通)。
// 画面単位ではなく関連画面をまとめた粒度で構成(1関数=複数画面)。Android は戻る DSL が無いため、
// 画面を変えるたびに scene 先頭で launchApp() し設定トップへリセットする(設定は system アプリで起動は失敗しない)。

import FTDSL

@TestClass(app: "com.android.settings", platform: "android")
class デモ_Android設定 {

    @Test("ネットワークと接続(ネットワークとインターネット・接続設定)を確認できる")
    func S0010() {
        scenario {
            scene(1, "ネットワークとインターネットを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("ネットワークとインターネット||Network & internet")
                }.expectation {
                    exist("#collapsing_toolbar")
                    exist("インターネット||Internet")
                }
            }
            scene(2, "一覧を上下にスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("インターネット||Internet")
                }
            }
            scene(3, "設定トップへ戻して接続設定を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("接続設定||Connected devices")
                }.expectation {
                    exist(".Other=接続設定||.Other=Connected devices")  // collapsing_toolbar のタイトル
                }
            }
            scene(4, "接続設定一覧を上下にスクロールする") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
        }
    }

    @Test("表示と通知(ディスプレイ・通知)を確認できる")
    func S0020() {
        scenario {
            scene(1, "ディスプレイ設定を開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("ディスプレイ||Display")
                    tap("ディスプレイ||Display")
                }.expectation {
                    exist("明るさのレベル||Brightness level")
                }
            }
            scene(2, "ダークモードまでスクロールして ON→OFF に戻す") {
                action {
                    scrollTo("ダークモード||Dark theme")
                    tap(".Switch=ダークモード||.Switch#switchWidget")
                    tap(".Switch=ダークモード||.Switch#switchWidget")
                }.expectation {
                    exist("ダークモード||Dark theme")
                }
            }
            scene(3, "設定トップへ戻して通知を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("通知||Notifications")
                }.expectation {
                    exist(".Other=通知||.Other=Notifications")  // collapsing_toolbar のタイトル
                }
            }
            scene(4, "通知一覧を上下にスクロールする") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
        }
    }

    @Test("電源と音(バッテリー・音とバイブレーション)を確認できる")
    func S0030() {
        scenario {
            scene(1, "バッテリー画面を開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("バッテリー||Battery")
                    tap("バッテリー||Battery")
                }.expectation {
                    exist("#usage_summary")  // 残量%の大型表示
                    exist("バッテリー使用量||Battery usage")
                }
            }
            scene(2, "バッテリーセーバーの項目まで上下にスクロールする") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("バッテリー セーバー||Battery Saver")
                }
            }
            scene(3, "設定トップへ戻して音とバイブレーションを開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("音とバイブレーション||Sound & vibration")
                    tap("音とバイブレーション||Sound & vibration")
                }.expectation {
                    exist("メディアの音量||Media volume")
                    exist("着信音の音量||Ring volume")
                }
            }
            scene(4, "アラームの音量までスクロールする") {
                action {
                    swipe(.up)
                }.expectation {
                    exist("アラームの音量||Alarm volume")
                }
            }
        }
    }

    // 「セキュリティとプライバシー」は不可: Android 16 では別パッケージ(SafetyCenter)が
    // 設定タスクの前面に残り、以後の launchApp の前面判定が全滅する
    @Test("デバイスとシステム(デバイス情報・アプリ・位置情報・ユーザー補助)を確認できる")
    func S0040() {
        scenario {
            scene(1, "デバイス情報を開く") {
                condition {
                    launchApp()
                }.action {
                    // Android 16/ja は「エミュレートされたデバイスについて」、15/en は「About emulated device」(実機は「デバイス情報」/「About phone」)
                    scrollTo("エミュレートされたデバイスについて||About emulated device||デバイス情報||About phone", maxSwipes: 12)
                    tap("エミュレートされたデバイスについて||About emulated device||デバイス情報||About phone")
                }.expectation {
                    exist("デバイス名||Device name")
                    exist("sdk_gphone64_arm64")
                }
            }
            scene(2, "Android バージョンとモデルまでスクロールする") {
                action {
                    scrollTo("Android バージョン||Android version", maxSwipes: 12)
                }.expectation {
                    exist("Android バージョン||Android version")
                    exist("モデル||Model")
                }
            }
            scene(3, "設定トップへ戻してアプリを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("アプリ||Apps")
                }.expectation {
                    exist(".Other=アプリ||.Other=Apps")  // collapsing_toolbar のタイトル
                }
            }
            scene(4, "設定トップへ戻して位置情報を開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("位置情報||Location", maxSwipes: 12)
                    tap("位置情報||Location")
                }.expectation {
                    exist(".Other=位置情報||.Other=Location")  // collapsing_toolbar のタイトル
                }
            }
            scene(5, "設定トップへ戻してユーザー補助を開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("ユーザー補助||Accessibility", maxSwipes: 12)
                    tap("ユーザー補助||Accessibility")
                }.expectation {
                    exist(".Other=ユーザー補助||.Other=Accessibility")  // collapsing_toolbar のタイトル
                }
            }
            scene(6, "ユーザー補助一覧を上下にスクロールする") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
        }
    }

    // scrollTo の direction 既定 .up=下方向へ送る、.down=上(先頭)へ戻す。到達先はいずれも既存シナリオで到達実績のある項目。
    @Test("設定トップを深くスクロールして各項目を辿れる")
    func S0050() {
        scenario {
            scene(1, "ユーザー補助まで下方向にスクロールする") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("ユーザー補助||Accessibility", maxSwipes: 15)
                }.expectation {
                    exist("ユーザー補助||Accessibility")
                }
            }
            scene(2, "さらに下端付近(デバイス情報)までスクロールする") {
                action {
                    scrollTo("エミュレートされたデバイスについて||About emulated device||デバイス情報||About phone", maxSwipes: 15)
                }.expectation {
                    exist("エミュレートされたデバイスについて||About emulated device||デバイス情報||About phone")
                }
            }
            scene(3, "先頭(ネットワークとインターネット)まで戻す") {
                action {
                    scrollTo("ネットワークとインターネット||Network & internet", direction: .down, maxSwipes: 20)
                }.expectation {
                    exist("ネットワークとインターネット||Network & internet")
                }
            }
            scene(4, "上下スワイプを繰り返して先頭に戻す") {
                action {
                    swipe(.up)
                    swipe(.up)
                    swipe(.down)
                    swipe(.down)
                }.expectation {
                    exist("ネットワークとインターネット||Network & internet")
                }
            }
        }
    }

    // アプリ切り替えデモ: 設定 ⇔ 時計(deskclock)。SampleApp は Android ビルドが存在しないため
    // 切替先はエミュ常設の時計アプリ。時計側のセレクタは未確認のため切替 scene は action のみ
    // (検証は戻り先の設定アプリで行う)。
    @Test("設定アプリと時計アプリを行き来できる")
    func S0060() {
        scenario {
            scene(1, "設定アプリを起動する") {
                condition {
                    launchApp()
                }.expectation {
                    exist("ネットワークとインターネット||Network & internet")
                }
            }
            scene(2, "時計アプリへ切り替える") {
                action {
                    launchApp("com.google.android.deskclock")
                    wait(1)  // 起動アニメーション整定待ち
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
                    exist("ネットワークとインターネット||Network & internet")
                }
            }
        }
    }
}
