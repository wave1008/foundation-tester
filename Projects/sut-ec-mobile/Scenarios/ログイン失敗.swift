// ログイン失敗.swift
// testbase: TC-80 の負側/第2段階の実認証(user-manual「誤ったパスワードでのログインはできません」)。
// 誤った資格情報ではログインできずエラーが出ることを検証する(負テスト・入力を伴う)。
// type を伴う。入力欄は id 付与済み(#field_email/#field_password)で解決は全エンジン共通だが:
//   - iOS: inapp のタップは Compose 入力欄をフォーカスできず type が 409 → フルアプリ XCUITest
//     ブリッジ(profiles/runs/ios-xcuitest.json, iosInappEngine=false)必須。`--profile ios-xcuitest` で実行。
//   - Android: inapp で type 可(ACTION_SET_TEXT・IME 不要)。→ iOS-inapp プロファイルには載せない。
// 失敗ログインはサーバ状態を作らないため副作用なし(正常ログイン/アカウント作成は専用テストアカウントが要る)。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP・修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile")  // iOS(xcuitest)/Android(inapp)対応。#id は両プラットフォーム共通
class ログイン失敗が表示されること {

    @Test("誤った資格情報ではログインできずエラーが出る")
    func S0010() {
        scenario {
            scene(1, "ログイン画面を開く") {
                condition {
                    launchApp()
                }.action {
                    ifCanSelect("#btn_back") { tap("#btn_back") }
                    tap("#tab_account")
                    tap("#btn_login", timeout: 5)  // アカウントの「ログイン / 登録」。セッション判定は非同期のため待つ
                }.expectation {
                    exist("#field_email")
                    exist("#btn_goto_signup")
                }
            }
            scene(2, "誤った資格情報でエラーが出る") {
                action {
                    // Compose 入力欄はフォーカスして input connection が張られるまで ACTION_SET_TEXT を
                    // 受け付けず 500 になる(Android inapp)。tap で先にフォーカスしてから type する
                    tap("#field_email")
                    type("#field_email", "nouser@example.com")
                    tap("#field_password")
                    type("#field_password", "wrongpass123")
                    tap("#btn_login")  // ログイン画面の送信ボタン(同 id・画面が別なので一意)
                }.expectation {
                    exist("ログインに失敗しました")
                }
            }
        }
    }
}
