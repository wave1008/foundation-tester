// ログイン失敗.swift
// ログイン画面が開き、必要な導線(メール/パスワード欄・ログイン・アカウント作成)が表示されることを検証。
//
// タイピングを伴う負テスト(誤認証→「ログインに失敗しました」)は現構成(engine=inapp)では未実装:
//   inapp(Compose)スナップショットでは入力欄が XCUITest と異なる型で公開され、フィールド本体を
//   安定セレクタで指せない(ラベル「メールアドレス」は隣接 StaticText に一致し、フォーカスできない)。
//   → 入力を要するフロー(ログイン成功/アカウント作成/チェックアウト等)は、run プロファイルを
//     engine=hybrid にして XCUITest フォールバックで入力欄を引くか、アプリ側で入力欄に
//     accessibilityIdentifier(testTag)を付けるかが前提。方針決定後に追加する。
// 正常ログイン/アカウント作成は実サーバにアカウントが永続登録されるため、専用テストアカウントも要る。
// セレクタは iPhone 17 Pro(iOS 27.0)/ja_JP・修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class ログイン画面を開けること {

    @Test("アカウントからログイン画面を開き入力導線が表示される")
    func S0010() {
        scenario {
            scene(1, "アカウントからログイン画面を開く") {
                condition {
                    launchApp()
                }.action {
                    // 押し込み画面から再開した場合に一覧へ正規化(タブ根なら無害)
                    ifCanSelect("戻る") { tap("#btn_back") }
                    wait(1)
                    tap("#tab_account")
                    wait(1)
                    tap(".Button=ログイン / 登録")
                    wait(1)
                }.expectation {
                    exist("メールアドレス")
                    exist("パスワード")
                    exist(".Button=ログイン")
                    exist(".Button=アカウントを作成")
                }
            }
        }
    }
}
