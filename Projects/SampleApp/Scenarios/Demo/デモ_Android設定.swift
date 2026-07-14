// デモ_Android設定.swift
// 4台並列デモ用(Android 設定アプリ)。
// エミュ1(Pixel 9/Android 16)=日本語、エミュ2(Pixel 9/Android 15)=英語のため全セレクタは 日本語||英語 の連鎖。
// サブ画面のタイトルは .Other#collapsing_toolbar のラベルで確認できる(全サブ画面共通)。

import FTDSL

@TestClass(app: "com.android.settings", platform: "android")
class デモ_Android設定 {

    @Test("ネットワークとインターネットを確認できる")
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
            scene(2, "一覧をスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("インターネット||Internet")
                }
            }
        }
    }

    @Test("ダークモードを切り替えて元に戻せる")
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
            scene(2, "ダークモードを ON にして OFF に戻す") {
                action {
                    scrollTo("ダークモード||Dark theme")
                    tap(".Switch=ダークモード||.Switch#switchWidget")
                    tap(".Switch=ダークモード||.Switch#switchWidget")
                }.expectation {
                    exist("ダークモード||Dark theme")
                }
            }
        }
    }

    @Test("バッテリー状態を確認できる")
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
            scene(2, "バッテリーセーバーの項目がある") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("バッテリー セーバー||Battery Saver")
                }
            }
        }
    }

    @Test("デバイス情報でモデルとバージョンを確認できる")
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
            scene(2, "Android バージョンまでスクロールする") {
                action {
                    scrollTo("Android バージョン||Android version", maxSwipes: 12)
                }.expectation {
                    exist("Android バージョン||Android version")
                    exist("モデル||Model")
                }
            }
        }
    }

    @Test("音とバイブレーションの音量項目が表示される")
    func S0050() {
        scenario {
            scene(1, "音とバイブレーションを開く") {
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
            scene(2, "アラームの音量まで確認する") {
                action {
                    swipe(.up)
                }.expectation {
                    exist("アラームの音量||Alarm volume")
                }
            }
        }
    }

    @Test("通知設定を開ける")
    func S0060() {
        scenario {
            scene(1, "通知を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("通知||Notifications")
                }.expectation {
                    exist(".Other=通知||.Other=Notifications")  // collapsing_toolbar のタイトル
                }
            }
            scene(2, "一覧をスクロールして眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
        }
    }

    @Test("接続設定を開ける")
    func S0070() {
        scenario {
            scene(1, "接続設定を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("接続設定||Connected devices")
                }.expectation {
                    exist(".Other=接続設定||.Other=Connected devices")  // collapsing_toolbar のタイトル
                }
            }
            scene(2, "一覧を眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
        }
    }

    @Test("アプリ設定を開ける")
    func S0080() {
        scenario {
            scene(1, "アプリを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("アプリ||Apps")
                }.expectation {
                    exist(".Other=アプリ||.Other=Apps")  // collapsing_toolbar のタイトル
                }
            }
            scene(2, "一覧を眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
        }
    }

    // 「セキュリティとプライバシー」は不可: Android 16 では別パッケージ(SafetyCenter)が
    // 設定タスクの前面に残り、以後の launchApp の前面判定が全滅する
    @Test("位置情報設定を開ける")
    func S0090() {
        scenario {
            scene(1, "位置情報を開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("位置情報||Location", maxSwipes: 12)
                    tap("位置情報||Location")
                }.expectation {
                    exist(".Other=位置情報||.Other=Location")  // collapsing_toolbar のタイトル
                }
            }
            scene(2, "一覧を眺める") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("#collapsing_toolbar")
                }
            }
        }
    }

    @Test("ユーザー補助を開ける")
    func S0100() {
        scenario {
            scene(1, "ユーザー補助を開く") {
                condition {
                    launchApp()
                }.action {
                    scrollTo("ユーザー補助||Accessibility", maxSwipes: 12)
                    tap("ユーザー補助||Accessibility")
                }.expectation {
                    exist(".Other=ユーザー補助||.Other=Accessibility")  // collapsing_toolbar のタイトル
                }
            }
            scene(2, "一覧をスクロールして眺める") {
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
