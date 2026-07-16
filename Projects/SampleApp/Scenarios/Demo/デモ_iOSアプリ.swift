// デモ_iOSアプリ.swift
// 4台並列デモ用(iOS 標準アプリ)。連絡先(@TestClass の app)を起点に、
// リマインダー・カレンダー・ファイルへ launchApp で切り替えて巡回する。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP で実機確認済み。連絡先・カレンダー・ファイルは
// 確認環境で初回ダイアログなし。リマインダーのみ「ようこそ」→iCloud同期確認 の2段ダイアログが出る
// (dismissRemindersOnboardingIfAny で消費済みでも安全に無害化)。
// 連絡先とリマインダーは launchApp() が直前の詳細/リスト画面から再開することがある
// (ensureContactsList / #BackButton の optional tap で一覧画面へ正規化してから進める)。
// 位置情報等の権限ダイアログが出るアプリ(マップ等)は対象外。状態を変える操作(表示切替等)は
// 同一 @Test 内で元に戻す。

import FTDSL

@TestClass(app: "com.apple.MobileAddressBook", platform: "ios")
class デモ_iOSアプリ {

    /// リマインダーの初回ダイアログ(ようこそ→iCloud同期確認)を消費する(出ない場合は無害)
    private func dismissRemindersOnboardingIfAny() {
        ifCanSelect("続ける", waitSeconds: 1) {
            tap("続ける")
        }
        wait(1)  // iCloud確認アラートは「続ける」後のアニメーション完了後に出る
        ifCanSelect("今はしない", waitSeconds: 1) {
            tap("今はしない")
        }
    }

    /// 連絡先は直前に開いていた詳細画面から再開することがあるため、一覧画面へ正規化する
    private func ensureContactsList() {
        ifCanSelect("#CNContactView", waitSeconds: 1) {
            tap("#BackButton")
        }
    }

    @Test("連絡先の一覧と詳細を確認できる")
    func S0010() {
        scenario {
            scene(1, "連絡先アプリを起動する") {
                condition {
                    launchApp()
                }.action {
                    ensureContactsList()
                }.expectation {
                    exist("#連絡先")
                    exist("John Appleseed")
                }
            }
            scene(2, "John Appleseed の詳細を確認する") {
                action {
                    tap("John Appleseed")
                }.expectation {
                    exist("#ContactCardHeaderView||John Appleseed")
                    exist("携帯電話")
                    exist("John-Appleseed@mac.com")
                }
            }
            scene(3, "一覧へ戻って末尾までスクロールする") {
                action {
                    tap("#BackButton")
                    scrollTo("Hank M. Zakroff", maxSwipes: 8)
                }.expectation {
                    exist("Hank M. Zakroff")
                }
            }
            scene(4, "先頭まで戻る") {
                action {
                    scrollTo("John Appleseed", direction: .down, maxSwipes: 8)
                }.expectation {
                    exist("John Appleseed")
                }
            }
        }
    }

    @Test("リマインダーのスマートリストとマイリストを確認できる")
    func S0020() {
        scenario {
            scene(1, "リマインダーを起動する") {
                condition {
                    launchApp("com.apple.reminders")
                }.action {
                    dismissRemindersOnboardingIfAny()
                }.expectation {
                    // 直前に開いていたリストへ戻る仕様のため、一覧/リスト詳細どちらでも
                    // 共通して出る「新規」ボタンで着地確認する
                    exist("新規")
                }
            }
            scene(2, "リスト一覧画面まで戻る") {
                action {
                    tap("#BackButton", optional: true, timeout: 1)
                }.expectation {
                    exist("#Reminders.TTRIAccountsListsView")
                    exist("今日")
                    exist("すべて")
                }
            }
            scene(3, "マイリストの「リマインダー」を開く") {
                action {
                    tap("リマインダー")
                }.expectation {
                    exist("#リマインダー")
                    exist("リマインダーなし")
                }
            }
            scene(4, "リスト一覧へ戻れる") {
                action {
                    tap("#BackButton")
                }.expectation {
                    exist("今日")
                }
            }
        }
    }

    @Test("カレンダーの表示切替と参照カレンダー一覧を確認できる")
    func S0030() {
        scenario {
            scene(1, "カレンダーを起動する") {
                condition {
                    launchApp("com.apple.mobilecal")
                }.expectation {
                    exist("#today-button")
                    exist("#calendars-button")
                    exist("#toggle-day-list-view")
                }
            }
            scene(2, "リスト表示に切り替えて祝日を確認する") {
                action {
                    tap("#toggle-day-list-view")
                    wait(1)  // 表示切替メニューのアニメーション整定待ち
                    tap("#list-view")
                }.expectation {
                    exist("#ListViewContainerView")
                    exist("元日")
                }
            }
            scene(3, "単一日表示に戻す") {
                action {
                    tap("#toggle-day-list-view")
                    wait(1)
                    tap("#single-day")
                }.expectation {
                    exist("#DayViewContainerView")
                    exist("#today-button")
                }
            }
            scene(4, "参照カレンダー一覧を確認して閉じる") {
                action {
                    tap("#calendars-button")
                }.expectation {
                    exist("日本の祝日")
                    exist("#show-completed-reminders-switch")
                }
            }
            scene(5, "カレンダー画面へ戻れる") {
                action {
                    tap("#done-button")
                }.expectation {
                    exist("#DayViewContainerView")
                }
            }
        }
    }

    @Test("ファイルの3タブとブラウズメニューを確認できる")
    func S0040() {
        scenario {
            scene(1, "ファイルを起動する") {
                condition {
                    launchApp("com.apple.DocumentsApp")
                }.expectation {
                    exist("#DOC.browsingModeTabBar")
                    exist("最近使った項目")
                }
            }
            scene(2, "共有タブを確認する") {
                action {
                    tap("共有")
                }.expectation {
                    exist("共有ファイルなし")
                }
            }
            scene(3, "ブラウズタブでメニューを開いて閉じる") {
                action {
                    tap("ブラウズ")
                    tap("#OverflowBarButtonItem")
                }.expectation {
                    exist("新規フォルダ")
                }
            }
            scene(4, "選択中の表示形式を選び直してメニューを閉じる") {
                action {
                    // 「アイコン」は表示中のメニューで選択済みのため、再選択しても状態は変わらず閉じるだけ
                    tap("アイコン")
                }.expectation {
                    exist("このiPhone内は空です")
                }
            }
            scene(5, "最近使った項目タブへ戻れる") {
                action {
                    tap("最近使った項目")
                }.expectation {
                    exist("最近使った項目")
                }
            }
        }
    }

    // アプリ切り替えデモ: 連絡先 ⇔ リマインダー。デモ_iOS設定.S0050 と同型のパターン。
    @Test("連絡先とリマインダーを行き来できる")
    func S0050() {
        scenario {
            scene(1, "連絡先アプリを起動する") {
                condition {
                    launchApp()
                }.action {
                    ensureContactsList()
                }.expectation {
                    exist("#連絡先")
                }
            }
            scene(2, "リマインダーへ切り替える") {
                action {
                    launchApp("com.apple.reminders")
                    dismissRemindersOnboardingIfAny()
                }.expectation {
                    exist("新規")
                }
            }
            scene(3, "ホーム経由でアプリスイッチャーを開く") {
                action {
                    home()
                    appSwitcher()
                }
            }
            scene(4, "連絡先アプリへ戻る") {
                action {
                    launchApp()
                    ensureContactsList()
                }.expectation {
                    exist("#連絡先")
                }
            }
        }
    }
}
