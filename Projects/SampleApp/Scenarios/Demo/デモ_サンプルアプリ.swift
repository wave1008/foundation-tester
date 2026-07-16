// デモ_サンプルアプリ.swift
// 4台並列デモ用(自作 SampleApp)。ログイン・タブ・リスト・コンテキストメニューを網羅する。
// セレクタは SampleApp/Sources/*.swift の accessibilityIdentifier と1対1(ソースが正)。
// ログイン状態はプロセス内 @State のみ(relaunchApp でログイン画面へリセットされる)。
// 各関数は ensureLoggedIn(ifCanSelect)で自己完結にし、実行順に依存しない。

import FTDSL

@TestClass(app: "com.example.sampleapp", platform: "ios")
class デモ_サンプルアプリ {

    /// iOS 27 のパスワード保存シートを閉じる(出た場合のみ)。アニメーション中のタップは
    /// 座標がずれて空振りする(タップ成功でもシート残留)ため、wait+再試行の2段構え
    private func dismissPasswordSheetIfAny() {
        wait(1)
        tap("今はしない", optional: true, timeout: 2)
        ifCanSelect("今はしない", waitSeconds: 1) {
            tap("今はしない")
        }
    }

    /// ログイン画面なら test@example.com でログインする(ログイン済みなら何もしない)
    private func ensureLoggedIn() {
        ifCanSelect("#email", waitSeconds: 2) {
            type("#email", "test@example.com")
            type("#password", "password123")
            tap("#login_btn||ログイン")
            dismissPasswordSheetIfAny()
        }
    }

    @Test("誤ったパスワードはエラーになり正しい情報でログインできる")
    func S0010() {
        scenario {
            scene(1, "誤ったパスワードでエラーが表示される") {
                condition {
                    relaunchApp()  // 前の関数のログイン状態を捨てて必ずログイン画面から
                }.action {
                    type("#email", "test@example.com")
                    type("#password", "wrong-pass")
                    tap("#login_btn||ログイン")
                }.expectation {
                    exist("#login_error||メールアドレスまたはパスワードが違います")
                }
            }
            scene(2, "正しいパスワードでログインできる") {
                condition {
                    relaunchApp()  // 入力欄はクリア不可(type は追記)のため再起動でリセット
                }.action {
                    type("#email", "test@example.com")
                    type("#password", "password123")
                    tap("#login_btn||ログイン")
                    dismissPasswordSheetIfAny()
                }.expectation {
                    exist("#welcome_text||ようこそ")
                }
            }
        }
    }

    @Test("商品リストをスクロールして端まで確認できる")
    func S0020() {
        scenario {
            scene(1, "ログインしてホームのリストを表示する") {
                condition {
                    launchApp()
                }.action {
                    ensureLoggedIn()
                }.expectation {
                    exist("#welcome_text||ようこそ")
                    exist("#item_りんご")
                }
            }
            scene(2, "リスト末尾の商品までスクロールする") {
                action {
                    scrollTo("#item_クランベリー", maxSwipes: 10)
                }.expectation {
                    exist("#item_クランベリー")
                }
            }
            scene(3, "先頭まで戻る") {
                action {
                    scrollTo("#item_りんご", direction: .down, maxSwipes: 10)
                }.expectation {
                    exist("#item_りんご")
                    exist("#welcome_text||ようこそ")
                }
            }
        }
    }

    @Test("長押しメニューでお気に入りを選択できる")
    func S0030() {
        scenario {
            scene(1, "ホームを表示する") {
                condition {
                    launchApp()
                }.action {
                    ensureLoggedIn()
                }.expectation {
                    exist("#item_りんご")
                }
            }
            scene(2, "りんごを長押しして お気に入り を選ぶ") {
                action {
                    press("#item_りんご", duration: 1.5)
                    tap("お気に入り")
                }.expectation {
                    exist("選択済み")
                }
            }
        }
    }

    @Test("設定タブでトグルを切り替えられる")
    func S0040() {
        scenario {
            scene(1, "設定タブを開く") {
                condition {
                    launchApp()
                }.action {
                    ensureLoggedIn()
                    tap("#tab_settings||設定")
                }.expectation {
                    // 型は縛らない: トグルは xcuitest=Switch / in-app エンジン=Button で露出が異なる
                    exist("#notif_toggle||通知")
                    exist("#darkmode_toggle||ダークモード")
                }
            }
            scene(2, "ダークモードを ON→OFF に戻す") {
                action {
                    tap("#darkmode_toggle||ダークモード")
                    tap("#darkmode_toggle||ダークモード")
                }.expectation {
                    exist("#darkmode_toggle||ダークモード")
                }
            }
            scene(3, "ホームタブへ戻れる") {
                action {
                    tap("#tab_home||ホーム")
                }.expectation {
                    exist("#welcome_text||ようこそ")
                }
            }
        }
    }

    @Test("ログアウトするとログイン画面に戻る")
    func S0050() {
        scenario {
            scene(1, "設定タブからログアウトする") {
                condition {
                    launchApp()
                }.action {
                    ensureLoggedIn()
                    tap("#tab_settings||設定")
                    tap("#logout_btn||ログアウト")
                }.expectation {
                    exist("#app_title||サンプルショップ")
                    exist("#email")
                }
            }
            scene(2, "再ログインできる") {
                action {
                    type("#email", "test@example.com")
                    type("#password", "password123")
                    tap("#login_btn||ログイン")
                    dismissPasswordSheetIfAny()
                }.expectation {
                    exist("#welcome_text||ようこそ")
                }
            }
        }
    }

    @Test("再起動するとログイン状態がリセットされる")
    func S0060() {
        scenario {
            scene(1, "ログイン済みの状態を作る") {
                condition {
                    launchApp()
                }.action {
                    ensureLoggedIn()
                }.expectation {
                    exist("#welcome_text||ようこそ")
                }
            }
            scene(2, "再起動でログイン画面へ戻る") {
                action {
                    relaunchApp()
                }.expectation {
                    exist("#app_title||サンプルショップ")
                    exist("#email")
                }
            }
        }
    }
}
