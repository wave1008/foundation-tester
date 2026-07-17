// デモ_Androidアプリ2.swift
// カレンダー(アカウント要件で非対応)を廃止し実証済みアプリへ差替。
// セレクタは既存合格ファイル(デモ_Androidアプリ.swift / デモ_Android時計.swift)からの流用のみ・新規推測禁止。
// 戻る DSL 無し→scene 先頭は launchApp。

import FTDSL

@TestClass(app: "com.google.android.documentsui", platform: "android")
class デモ_Androidアプリ2 {

    @Test("Filesアプリで内部ストレージのフォルダ構成と表示形式を確認できる")
    func S0010() {
        scenario {
            scene(1, "内部ストレージを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("ルートを表示||Show roots")
                    tap("sdk_gphone64_arm64")
                }.expectation {
                    exist("DCIM")
                    exist("Download")
                }
            }
            scene(2, "スクロールしてPicturesとMusicも確認する") {
                action {
                    swipe(.up)
                    swipe(.down)
                }.expectation {
                    exist("Pictures")
                    exist("Music")
                }
            }
            scene(3, "リスト表示とグリッド表示を切り替えて戻す") {
                action {
                    tap("リスト表示||List view")
                    tap("グリッド表示||Grid view")
                }.expectation {
                    exist("リスト表示||List view")
                }
            }
        }
    }

    @Test("Filesアプリで画像フォルダを経由してから内部ストレージを検索できる(結果は確認して戻る)")
    func S0020() {
        scenario {
            scene(1, "ルート一覧から画像フォルダへ切り替える") {
                condition {
                    launchApp()
                }.action {
                    tap("ルートを表示||Show roots")
                    tap("画像||Images")
                }.expectation {
                    exist(".StaticText=画像||.StaticText=Images")
                }
            }
            scene(2, "内部ストレージへ切り替えて検索する") {
                action {
                    tap("ルートを表示||Show roots")
                    tap("sdk_gphone64_arm64")
                    tap("#option_menu_search")
                    type("#search_src_text", "xyzzynotfound")
                }.expectation {
                    exist("#message")
                }
            }
            scene(3, "検索を閉じて内部ストレージへ戻る") {
                action {
                    tap("戻る||Back")
                }.expectation {
                    exist("#breadcrumb_text")
                }
            }
        }
    }

    @Test("時計アプリで世界時計タブと就寝タブを続けて表示できる")
    func S0030() {
        scenario {
            scene(1, "時計タブを開く") {
                condition {
                    launchApp("com.google.android.deskclock")
                }.action {
                    tap("#tab_menu_clock")
                }.expectation {
                    exist("#action_bar_title")
                }
            }
            scene(2, "おやすみ時間タブへ切り替える") {
                action {
                    tap("#tab_menu_bedtime")
                }.expectation {
                    exist("#action_bar_title")
                }
            }
        }
    }

    @Test("時計アプリでタイマーに桁を入力してからストップウォッチを開始・停止できる")
    func S0040() {
        scenario {
            scene(1, "タイマータブを開く") {
                condition {
                    launchApp("com.google.android.deskclock")
                }.action {
                    tap("#tab_menu_timer")
                }.expectation {
                    exist("#timer_setup_digit_1")
                }
            }
            scene(2, "数字を入力する(開始はしない)") {
                action {
                    tap("#timer_setup_digit_1")
                    tap("#timer_setup_digit_2")
                }.expectation {
                    exist("#action_bar_title")
                }
            }
            scene(3, "ストップウォッチタブへ切り替えて開始・停止する(元に戻す)") {
                action {
                    tap("#tab_menu_stopwatch")
                    tap("#start_stop_button||#fab")
                    wait(1)
                    tap("#start_stop_button||#fab")
                }.expectation {
                    exist("#action_bar_title")
                }
            }
        }
    }

    @Test("連絡先アプリの検索と整理タブから設定画面を確認できる(データは作成しない)")
    func S0050() {
        scenario {
            scene(1, "連絡先アプリを起動する(初回の通知許可は許可しない)") {
                condition {
                    launchApp("com.google.android.contacts")
                }.action {
                    ifCanSelect("#permission_deny_button", waitSeconds: 2) {
                        tap("#permission_deny_button")
                    }
                }.expectation {
                    exist("#contacts")
                }
            }
            scene(2, "検索してから閉じる") {
                action {
                    tap("#open_search_bar")
                    type("#open_search_view_edit_text", "xyzzynotfound")
                    tap("戻る||Back")
                }.expectation {
                    exist("#contacts")
                }
            }
            scene(3, "整理タブから設定画面を確認する(閲覧のみ)") {
                action {
                    tap("#nav_organize")
                    tap("設定||Settings")
                }.expectation {
                    exist("自分の情報||My info")
                }
            }
        }
    }
}
