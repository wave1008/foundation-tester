// ログイン入力バリデーション.swift
// testbase TC-130/131/132(SC-130/131/132): ログインの空欄・空白入力は失敗しエラー表示(isBlank 判定)。
// 【engine=xcuitest 専用】: 入力を伴うため ios-xcuitest プロファイルで実行する(inapp は入力欄をフォーカス不可)。
// 失敗ログインはサーバ状態を作らないため副作用なし。セレクタは修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class ログイン入力バリデーションが働くこと {

    /// アカウント → ログイン画面を開く
    private func openLogin() {
        ifCanSelect("#btn_back") { tap("#btn_back") }
        tap("#tab_account")
        tap("#btn_login")
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
                    type("#field_email", "   ")
                    type("#field_password", "   ")
                    tap("#btn_login")
                }.expectation {
                    exist("ログインに失敗しました")
                }
            }
        }
    }
}
