// デモ_Android時計.swift
// 4台並列デモ用(時計アプリ com.google.android.deskclock)。エミュ標準搭載・初回ダイアログなし。
// タブは #tab_menu_*(id、ロケール非依存)。画面タイトルは #action_bar_title で確認する。
// 状態を汚す操作(アラーム ON/OFF・ストップウォッチ)は同 scene 内で元に戻す。

import FTDSL

@TestClass(app: "com.google.android.deskclock", platform: "android")
class デモ_Android時計 {

    // アラームの有無はエミュ個体差(既定アラームが無い環境あり)。一覧コンテナ(#alarm_recycler_view)と
    // 追加ボタン(#fab)は空でも存在するため、これらをアンカーにする
    @Test("アラーム一覧が表示される")
    func S0010() {
        scenario {
            scene(1, "アラームタブを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_menu_alarm")
                }.expectation {
                    exist("#alarm_recycler_view")
                    exist("#fab")
                }
            }
        }
    }

    @Test("アラームがあれば ON にして OFF に戻せる")
    func S0020() {
        scenario {
            scene(1, "アラームタブを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_menu_alarm")
                }.expectation {
                    exist("#alarm_recycler_view")
                }
            }
            scene(2, "アラームがある場合のみスイッチを2回タップして元に戻す") {
                action {
                    ifCanSelect(".Switch#onoff", waitSeconds: 1) {
                        tap(".Switch#onoff")
                        wait(1)  // ON 直後のスナックバー表示の整定待ち
                        tap(".Switch#onoff")
                    }
                }.expectation {
                    exist("#alarm_recycler_view")
                }
            }
        }
    }

    @Test("世界時計に現在時刻と日付が表示される")
    func S0030() {
        scenario {
            scene(1, "時計タブを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_menu_clock")
                }.expectation {
                    exist("#digital_clock")
                    exist("#current_date||#date_and_next_alarm")  // A16=current_date / A15=date_and_next_alarm
                }
            }
        }
    }

    @Test("タイマーの時間入力ができる")
    func S0040() {
        scenario {
            scene(1, "タイマータブを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_menu_timer")
                }.expectation {
                    exist("#timer_setup_time")
                    exist("#timer_setup_digit_1")
                }
            }
            scene(2, "数字を入力できる(開始はしない)") {
                action {
                    tap("#timer_setup_digit_1")
                    tap("#timer_setup_digit_2")
                }.expectation {
                    exist("#timer_setup_time")
                }
            }
        }
    }

    @Test("ストップウォッチを開始・停止できる")
    func S0050() {
        scenario {
            scene(1, "ストップウォッチタブを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_menu_stopwatch")
                }.expectation {
                    exist("#stopwatch_time_text")
                }
            }
            scene(2, "開始して一時停止する") {
                action {
                    // A16=start_stop_button / A15=fab(ストップウォッチタブ内なので fab=開始/停止)
                    tap("#start_stop_button||#fab")   // 開始
                    wait(1)
                    tap("#start_stop_button||#fab")   // 一時停止
                }.expectation {
                    exist("#stopwatch_time_text")
                }
            }
        }
    }

    @Test("おやすみ時間タブを表示できる")
    func S0060() {
        scenario {
            scene(1, "おやすみ時間タブを開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#tab_menu_bedtime")
                }.expectation {
                    exist("#action_bar_title")
                }
            }
            scene(2, "アラームタブへ戻れる") {
                action {
                    tap("#tab_menu_alarm")
                }.expectation {
                    exist("#alarm_recycler_view||#fab")
                }
            }
        }
    }
}
