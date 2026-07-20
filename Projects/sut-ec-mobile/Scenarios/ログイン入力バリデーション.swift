// ログイン入力バリデーション.swift
// testbase TC-130/131/132(SC-130/131/132): ログインの空欄・空白入力は失敗しエラー表示(isBlank 判定)。
// type を伴う。iOS-hybrid(all/ios プロファイル)は Compose 自動判定で type だけ XCUITest 実行に
// 切り替わるためそのまま通る(2026-07-20〜。docs/design.md §セレクタの hybrid type 項)。
// engine=inapp 単独のプロファイルにだけは載せない(type が 409)。
// Android は inapp で type 可(ACTION_SET_TEXT・IME 不要)。
// 失敗ログインはサーバ状態を作らないため副作用なし。セレクタは修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile")  // iOS(xcuitest)/Android(inapp)対応。#id は両プラットフォーム共通
class ログイン入力バリデーションが働くこと {

    /// アカウント → ログイン画面を開く
    private func openLogin() {
        ifCanSelect("#btn_back") { tap("#btn_back") }
        tap("#tab_account")
        tap("#btn_login", timeout: 5)  // アカウントのセッション判定は非同期。logged-out で「ログイン / 登録」が出るまで待つ
    }

    @Test("メール空欄ではログインできずエラーが出る")
    func S0010() {
        scenario {
            scene(1, "ログイン画面を開く") {
                condition {
                    launchApp()
                }.action {
                    openLogin()
                }.expectation {
                    exist("#field_email")
                }
            }
            scene(2, "メール空・パスワードのみで失敗") {
                action {
                    // Compose 入力欄はフォーカスして input connection が張られるまで ACTION_SET_TEXT を
                    // 受け付けず 500 になる(Android inapp)。tap で先にフォーカスしてから type する
                    tap("#field_password")
                    type("#field_password", "somepassword")
                    tap("#btn_login")
                }.expectation {
                    exist("ログインに失敗しました")
                }
            }
        }
    }

    @Test("パスワード空欄ではログインできずエラーが出る")
    func S0020() {
        scenario {
            scene(1, "ログイン画面を開く") {
                condition {
                    launchApp()
                }.action {
                    openLogin()
                }.expectation {
                    exist("#field_email")
                }
            }
            scene(2, "パスワード空・メールのみで失敗") {
                action {
                    tap("#field_email")  // フォーカスしてから type(Android inapp の ACTION_SET_TEXT 対策)
                    type("#field_email", "someone@example.com")
                    tap("#btn_login")
                }.expectation {
                    exist("ログインに失敗しました")
                }
            }
        }
    }

    @Test("空白のみの入力ではログインできずエラーが出る")
    func S0030() {
        scenario {
            scene(1, "ログイン画面を開く") {
                condition {
                    launchApp()
                }.action {
                    openLogin()
                }.expectation {
                    exist("#field_email")
                }
            }
            scene(2, "メール/パスワードに空白のみで失敗") {
                action {
                    tap("#field_email")  // フォーカスしてから type(Android inapp の ACTION_SET_TEXT 対策)
                    type("#field_email", "   ")
                    tap("#field_password")
                    type("#field_password", "   ")
                    tap("#btn_login")
                }.expectation {
                    exist("ログインに失敗しました")
                }
            }
        }
    }
}
