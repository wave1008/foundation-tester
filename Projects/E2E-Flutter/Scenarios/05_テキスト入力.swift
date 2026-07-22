// 05_テキスト入力.swift
// ftester 機能: `type` コマンドと入力値の echo 検証(単一行/パスワード/送信/クリア)。
// Flutter の `obscureText: true` は **`SecureTextField` にならない**(iOS/Android とも `TextField`)。
// ネイティブ SUT のように型でパスワード欄を区別できないため、`#id` で引く。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class テキスト入力が正しくechoされること {

    @Test("単一行・パスワードの入力値が echo され送信/クリアが効く")
    func S0010() {
        scenario {
            scene(1, "テキスト入力画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    exist("#txt_home_marker")
                }.action {
                    tap("#nav_input")
                }.expectation {
                    textIs("#txt_echo_single", "single=")
                }
            }
            scene(2, "単一行に入力して echo される") {
                action {
                    // Android は input connection が張られるまで ACTION_SET_TEXT を受け付けない
                    // (500「ACTION_SET_TEXT を受け付けないフィールドです」で落ちる)。Flutter は
                    // この接続確立が tap 応答より遅れるため、tap と type の間に1往復挟んで待つ。
                    tap("#field_single")
                }.expectation {
                    exist("#field_single")
                }.action {
                    type("#field_single", "hello123")
                }.expectation {
                    textIs("#txt_echo_single", "single=hello123")
                    textIs("#txt_echo_length", "len=8")
                }
            }
            scene(3, "パスワード欄も平文で echo される") {
                action {
                    tap("#field_password")
                }.expectation {
                    exist("#field_password")
                }.action {
                    type("#field_password", "secret42")
                }.expectation {
                    textIs("#txt_echo_password", "password=secret42")
                }
            }
            scene(4, "送信で submitted に反映される") {
                action {
                    tap("#btn_input_submit")
                }.expectation {
                    textIs("#txt_input_submitted", "submitted=hello123")
                }
            }
            scene(5, "クリアで全フィールドと submitted が初期化される") {
                action {
                    tap("#btn_input_clear")
                }.expectation {
                    textIs("#txt_echo_single", "single=")
                    textIs("#txt_input_submitted", "submitted=-")
                }
            }
        }
    }
}
