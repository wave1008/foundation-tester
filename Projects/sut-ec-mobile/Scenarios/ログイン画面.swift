// ログイン画面.swift
// testbase: ログイン画面表示(TC-80/TC-130 の前段=アカウント→ログイン画面への遷移と入力導線の表示)。
// ログイン画面が開き、必要な導線(メール/パスワード欄・ログイン・アカウント作成)が表示されることを検証。
// タイピングは行わない表示専用テストなので inapp/iOS/Android すべてで通る(入力を伴う負テストは
// ログイン失敗.swift / ログイン入力バリデーション.swift 側。iOS は xcuitest プロファイル必須)。
// 入力欄・ボタンは #field_email/#field_password/#btn_login/#btn_goto_signup(testTag)で指す。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP・修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile")  // iOS/Android 両対応(#id は testTag→resource-id/accessibilityId で共通)
class ログイン画面を開けること {

    @Test("アカウントからログイン画面を開き入力導線が表示される")
    func S0010() {
        scenario {
            scene(1, "アカウントからログイン画面を開く") {
                condition {
                    launchApp()
                }.action {
                    // 押し込み画面から再開した場合に一覧へ正規化(タブ根なら無害)
                    ifCanSelect("#btn_back") { tap("#btn_back") }
                    tap("#tab_account")
                    tap("#btn_login", timeout: 5)  // アカウントの「ログイン / 登録」。セッション判定は非同期のため待つ
                }.expectation {
                    exist("#field_email")       // メール欄
                    exist("#field_password")    // パスワード欄
                    exist("#btn_login")         // ログイン画面の送信ボタン(同 id・画面が別なので一意)
                    exist("#btn_goto_signup")   // アカウント作成へ
                }
            }
        }
    }
}
