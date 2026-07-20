// サインアップ入力バリデーション.swift
// testbase TC-133(SC-133): サインアップで必須(名前/メール/パスワード)を空にして登録 → 失敗し登録されない。
// 【engine=xcuitest 専用】(入力欄フォーカスのため)。
// 安全策: 全欄を空のまま「登録」を押す(バリデーションで弾かれ、アカウントは作成されない=サーバ副作用なし)。
// 「登録されない」= サインアップ画面に留まる(#field_name が残存)ことで確認する。セレクタは修正版ビルドで採取。

import FTDSL

@TestClass(app: "com.sutec.mobile", platform: "ios")
class サインアップ入力バリデーションが働くこと {

    @Test("必須項目が空だと登録されない")
    func S0010() {
        scenario {
            scene(1, "サインアップ画面を開く") {
                condition {
                    launchApp()
                }.action {
                    ifCanSelect("#btn_back") { tap("#btn_back") }
                    tap("#tab_account")
                    tap("#btn_login")
                    tap("#btn_goto_signup")
                }.expectation {
                    exist("#field_name")
                    exist("#btn_signup")
                }
            }
            scene(2, "全欄空のまま登録すると弾かれる") {
                action {
                    tap("#btn_signup")  // 何も入力せず登録(バリデーションで失敗・アカウント未作成)
                }.expectation {
                    exist("#field_name")  // サインアップ画面に留まる=登録されていない
                    exist("#btn_signup")
                }
            }
        }
    }
}
