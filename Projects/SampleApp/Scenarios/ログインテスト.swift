// LoginTest.swift
// SampleApp のログインシナリオ(Swift DSL のサンプル)。
// 実行: swift run ftester run --scenario ログインテスト.S0010

import FTDSL

@TestClass(app: "com.example.sampleapp")
class ログインテスト {

    @Test("ログインとエラー表示")
    func S0010() {
        scenario {
            scene(1, "正しい認証情報でログインできる") {
                condition {
                    launchApp()
                }.action {
                    tap("#email")
                    type("test@example.com")
                    tap("#password")
                    type("password123")
                    tap("#login_btn||ログイン")
                    wait(1)  // iOS 27 のパスワード保存シートの出現アニメーション整定待ち
                    tap("今はしない", optional: true, timeout: 2)  // シートが出た場合のみ閉じる(出ない個体もある)
                    ifCanSelect("今はしない", waitSeconds: 1) {  // アニメ中タップの空振り(シート残留)への再試行
                        tap("今はしない")
                    }
                }.expectation {
                    exist("#welcome_text||ようこそ")
                }
            }
            scene(2, "誤ったパスワードはエラー表示") {
                condition {
                    relaunchApp()
                }.action {
                    tap("#email")
                    type("test@example.com")
                    tap("#password")
                    type("wrong")
                    tap("#login_btn||ログイン")
                }.expectation {
                    exist("#login_error")
                        .textIs("メールアドレスまたはパスワードが違います")
                }
            }
        }
    }
}
