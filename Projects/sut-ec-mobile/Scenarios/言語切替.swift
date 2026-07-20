// 言語切替.swift
// testbase: TC-90(SC-90)言語トグル即時反映(日本語↔English)。
// アカウント画面の言語トグル(日本語 / English)で UI 表示言語が切り替わることを検証する。
// トグルボタンのラベルは常に「日本語」「English」(切替先の言語名)なので、どちらのモードでも id で押せる。
// 言語設定は永続する(実行を跨ぐ)ため、末尾で必ず日本語へ戻す(他シナリオは日本語ラベルを前提)。
// 入力を伴わないので inapp/xcuitest どちらでも動く。セレクタは修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class 言語を切り替えられること {

    @Test("日本語とEnglishを切り替えられる")
    func S0010() {
        scenario {
            scene(1, "アカウントを開き日本語を基準化") {
                condition {
                    launchApp()
                }.action {
                    // 押し込み画面から再開した場合に戻す(id なので言語非依存)
                    ifCanSelect("#btn_back") { tap("#btn_back") }
                    tap("#tab_account")
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
