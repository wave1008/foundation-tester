// ログイン失敗.swift
// testbase: TC-80 の負側/第2段階の実認証(user-manual「誤ったパスワードでのログインはできません」)。
// 誤った資格情報ではログインできずエラーが出ることを検証する(負テスト・入力を伴う)。
// 【engine=xcuitest 専用】: 入力欄は id 付与済み(#field_email/#field_password)で解決は両エンジンで
// できるが、inapp のタップは Compose 入力欄をフォーカスできず type が 409 になる。フルアプリ XCUITest
// ブリッジ(profiles/runs/ios-xcuitest.json, iosInappEngine=false)でのみタイピングが通る。
// → このシナリオは `--profile ios-xcuitest` で実行する。
// 失敗ログインはサーバ状態を作らないため副作用なし(正常ログイン/アカウント作成は専用テストアカウントが要る)。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP・修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class ログイン失敗が表示されること {

    @Test("誤った資格情報ではログインできずエラーが出る")
    func S0010() {
        scenario {
            scene(1, "ログイン画面を開く") {
                condition {
                    launchApp()
                }.action {
                    ifCanSelect("戻る") { tap("#btn_back") }
                    tap("#tab_account")
                    tap("#btn_login")  // アカウント画面の「ログイン / 登録」
                }.expectation {
                    exist("#field_email")
                    exist("#btn_goto_signup")
                }
            }
            scene(2, "誤った資格情報でエラーが出る") {
                action {
                    type("#field_email", "nouser@example.com")
                    type("#field_password", "wrongpass123")
                    tap("#btn_login")  // ログイン画面の送信ボタン(同 id・画面が別なので一意)
                }.expectation {
                    exist("ログインに失敗しました")
                }
            }
        }
    }
}
