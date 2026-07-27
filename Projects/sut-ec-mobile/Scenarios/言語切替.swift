// 言語切替.swift
// testbase: TC-90(SC-90)言語トグル即時反映(日本語↔English)。
// アカウント画面の言語トグル(日本語 / English)で UI 表示言語が切り替わることを検証する。
// トグルボタンのラベルは常に「日本語」「English」(切替先の言語名)なので、どちらのモードでも id で押せる。
// 言語設定は永続する(実行を跨ぐ)ため、必ず日本語へ戻す(他シナリオは日本語ラベルを前提)。
// 戻しは scene 3(緑経路の往復検証を兼ねる)に加えて tearDown でも行う — 失敗はシナリオ全体を
// 中断するので、scene 3 だけだと失敗時に English が残り後続シナリオが全滅する。
// 入力を伴わないので inapp/xcuitest どちらでも動く。セレクタは修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile")  // iOS/Android 両対応(#id は testTag→resource-id/accessibilityId で共通)
class 言語を切り替えられること {

    // 状態の正規化(各 @Test の前に毎回実行される)。launchApp は直前画面から再開するため、
    // 既知の開始点へ揃えてからテスト本体を走らせる
    func setUp() {
        launchApp()
        // 押し込み画面から再開した場合に戻す(id なので言語非依存)
        ifCanSelect("#btn_back") { tap("#btn_back") }
        tap("#tab_account")
    }

    // 失敗後でも必ず日本語へ戻す(tearDown は失敗後でも実行される)。ボタンは id 指定なので
    // English のままでも押せる。既に日本語なら押しても無害(トグルではなく選択)
    func tearDown() {
        ifCanSelect("#btn_back") { tap("#btn_back") }
        ifCanSelect("#tab_account") { tap("#tab_account") }
        ifCanSelect("#btn_toggle_language_ja", waitSeconds: 1) { tap("#btn_toggle_language_ja") }
    }

    @Test("日本語とEnglishを切り替えられる")
    func S0010() {
        scenario {
            scene(1, "アカウントを開き日本語を基準化") {
                action {
                    // 前回残留が English でも日本語へ正規化(既に日本語なら無害)
                    tap("#btn_toggle_language_ja")
                }.expectation {
                    exist("アカウント")
                    exist("ログイン / 登録")
                }
            }
            scene(2, "Englishに切り替える") {
                action {
                    tap("#btn_toggle_language_en")
                }.expectation {
                    exist("Account")
                    exist("Log in / Sign up")  // UI が英語化した
                }
            }
            scene(3, "後始末: 日本語に戻す") {
                action {
                    tap("#btn_toggle_language_ja")
                }.expectation {
                    exist("アカウント")
                    exist("ログイン / 登録")
                }
            }
        }
    }
}
