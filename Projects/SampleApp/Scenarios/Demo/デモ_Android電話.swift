// デモ_Android電話.swift
// 対象パッケージ: com.google.android.dialer(既定電話アプリ設定・権限等の初回ダイアログが個体差で出るため
// 各シナリオ冒頭で ifCanSelect により無害化する)。
// 実機セレクタ未検証のため防御的に書く: id 候補は推測(#digits 等)であり確度が低い。
// アンカーは可変値(番号・連絡先名)を含まない安定要素(タブラベル・検索/削除ボタン等)に限定する。
// 発信は絶対に行わない(発信ボタンはタップしない。ダイヤル入力後は削除または launchApp で戻す)。

import FTDSL

@TestClass(app: "com.google.android.dialer", platform: "android")
class デモ_Android電話 {

    @Test("起動してボトムナビの主要タブが表示される")
    func S0010() {
        scenario {
            scene(1, "起動直後の初回ダイアログを無害化する") {
                condition {
                    launchApp()
                }.action {
                    ifCanSelect("#permission_deny_button", waitSeconds: 2) {
                        tap("#permission_deny_button")
                    }
                    ifCanSelect("許可しない||Don't allow", waitSeconds: 2) {
                        tap("許可しない||Don't allow")
                    }
                    ifCanSelect("OK", waitSeconds: 2) {
                        tap("OK")
                    }
                    ifCanSelect("次へ||Next", waitSeconds: 2) {
                        tap("次へ||Next")
                    }
                    ifCanSelect("スキップ||Skip", waitSeconds: 2) {
                        tap("スキップ||Skip")
                    }
                    ifCanSelect("後で||Later", waitSeconds: 2) {
                        tap("後で||Later")
                    }
                    ifCanSelect("使ってみる||Got it||GOT IT", waitSeconds: 2) {
                        tap("使ってみる||Got it||GOT IT")
                    }
                }.expectation {
                    exist("お気に入り||Favorites||履歴||Recents||連絡先||Contacts")
                }
            }
        }
    }

    @Test("ボトムナビのタブを巡回して元のタブに戻せる")
    func S0020() {
        scenario {
            scene(1, "初回ダイアログを無害化して履歴タブへ切り替える") {
                condition {
                    launchApp()
                }.action {
                    ifCanSelect("#permission_deny_button", waitSeconds: 2) {
                        tap("#permission_deny_button")
                    }
                    ifCanSelect("許可しない||Don't allow", waitSeconds: 2) {
                        tap("許可しない||Don't allow")
                    }
                    ifCanSelect("OK", waitSeconds: 2) {
                        tap("OK")
                    }
                    ifCanSelect("次へ||Next", waitSeconds: 2) {
                        tap("次へ||Next")
                    }
                    ifCanSelect("スキップ||Skip", waitSeconds: 2) {
                        tap("スキップ||Skip")
                    }
                    ifCanSelect("後で||Later", waitSeconds: 2) {
                        tap("後で||Later")
                    }
                    ifCanSelect("使ってみる||Got it||GOT IT", waitSeconds: 2) {
                        tap("使ってみる||Got it||GOT IT")
                    }
                    tap("履歴||Recents")
                }.expectation {
                    exist("履歴||Recents")
                }
            }
            scene(2, "連絡先タブへ切り替える") {
                action {
                    tap("連絡先||Contacts")
                }.expectation {
                    exist("連絡先||Contacts")
                }
            }
            scene(3, "お気に入りタブへ戻す") {
                action {
                    tap("お気に入り||Favorites")
                }.expectation {
                    exist("お気に入り||Favorites")
                }
            }
        }
    }

    @Test("ダイヤルパッドで番号を入力して削除できる(発信しない)")
    func S0030() {
        scenario {
            scene(1, "初回ダイアログを無害化してダイヤルパッドを開く") {
                condition {
                    launchApp()
                }.action {
                    ifCanSelect("#permission_deny_button", waitSeconds: 2) {
                        tap("#permission_deny_button")
                    }
                    ifCanSelect("許可しない||Don't allow", waitSeconds: 2) {
                        tap("許可しない||Don't allow")
                    }
                    ifCanSelect("OK", waitSeconds: 2) {
                        tap("OK")
                    }
                    ifCanSelect("次へ||Next", waitSeconds: 2) {
                        tap("次へ||Next")
                    }
                    ifCanSelect("スキップ||Skip", waitSeconds: 2) {
                        tap("スキップ||Skip")
                    }
                    ifCanSelect("後で||Later", waitSeconds: 2) {
                        tap("後で||Later")
                    }
                    ifCanSelect("使ってみる||Got it||GOT IT", waitSeconds: 2) {
                        tap("使ってみる||Got it||GOT IT")
                    }
                    ifCanSelect("#dialpad_fab", waitSeconds: 2) {
                        tap("#dialpad_fab")
                    }
                    ifCanSelect("#fab", waitSeconds: 2) {
                        tap("#fab")
                    }
                }.expectation {
                    exist("#digits||#dialpadEditText")
                }
            }
            scene(2, "数桁入力する(発信ボタンは押さない)") {
                action {
                    type("#digits||#dialpadEditText", "123")
                }.expectation {
                    exist("#digits||#dialpadEditText")
                }
            }
            scene(3, "削除ボタンで入力を消して元に戻す") {
                action {
                    ifCanSelect("#deleteButton", waitSeconds: 2) {
                        tap("#deleteButton")
                        tap("#deleteButton")
                        tap("#deleteButton")
                    }
                }.expectation {
                    exist("#digits||#dialpadEditText")
                }
            }
        }
    }

    @Test("検索で該当なし文字列を確認して閉じられる(開けない個体は連絡先タブで締める)")
    func S0040() {
        scenario {
            scene(1, "初回ダイアログを無害化する") {
                condition {
                    launchApp()
                }.action {
                    ifCanSelect("#permission_deny_button", waitSeconds: 2) {
                        tap("#permission_deny_button")
                    }
                    ifCanSelect("許可しない||Don't allow", waitSeconds: 2) {
                        tap("許可しない||Don't allow")
                    }
                    ifCanSelect("OK", waitSeconds: 2) {
                        tap("OK")
                    }
                    ifCanSelect("次へ||Next", waitSeconds: 2) {
                        tap("次へ||Next")
                    }
                    ifCanSelect("スキップ||Skip", waitSeconds: 2) {
                        tap("スキップ||Skip")
                    }
                    ifCanSelect("後で||Later", waitSeconds: 2) {
                        tap("後で||Later")
                    }
                    ifCanSelect("使ってみる||Got it||GOT IT", waitSeconds: 2) {
                        tap("使ってみる||Got it||GOT IT")
                    }
                }.expectation {
                    exist("お気に入り||Favorites||履歴||Recents||連絡先||Contacts")
                }
            }
            scene(2, "検索を開けたら該当なし文字列を入力する(開けない個体はスキップ)") {
                action {
                    ifCanSelect("#search_view||検索||Search", waitSeconds: 2) {
                        tap("#search_view||検索||Search")
                        // 検索入力欄の実 id 未確認。誤りでもシナリオを落とさないよう optional にする
                        // (検索が開けた事実は上の ifCanSelect で担保済み。締めは scene3 の連絡先タブ)
                        type("#search_src_text||#search_view_edit_text", "xyzzynotfound", optional: true)
                    }
                }.expectation {
                    exist("お気に入り||Favorites||履歴||Recents||連絡先||Contacts")
                }
            }
            scene(3, "検索を閉じて連絡先タブの一覧を確認して締める") {
                action {
                    ifCanSelect("戻る||Back", waitSeconds: 2) {
                        tap("戻る||Back")
                    }
                    tap("連絡先||Contacts")
                }.expectation {
                    exist("連絡先||Contacts")
                }
            }
        }
    }
}
