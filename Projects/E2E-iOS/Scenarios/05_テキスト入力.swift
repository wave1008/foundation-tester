// 05_テキスト入力.swift
// ftester 機能: `type` コマンドと入力値の echo 検証(単一行/パスワード/送信/クリア)。
// SUT の入力欄は **UIKit の UITextField / UITextView**(SwiftUI TextField ではない)。
// ツリー上の型は TextField / SecureTextField / TextView に分かれるため、型セレクタでも引ける。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class テキスト入力が正しくechoされること {

    @Test("単一行・パスワードの入力値が echo され送信/クリアが効く")
    func S0010() {
        scenario {
            scene(1, "テキスト入力画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_input")
                }.expectation {
                    textIs("#txt_echo_single", "single=")
                }
            }
            scene(2, "単一行に入力して echo される") {
                action {
                    tap("#field_single")
                    type("#field_single", "hello123")
                }.expectation {
                    textIs("#txt_echo_single", "single=hello123")
                    textIs("#txt_echo_length", "len=8")
                }
            }
            scene(3, "パスワード欄も平文で echo される") {
                action {
                    tap("#field_password")
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

    @Test("UIKit 入力欄は型セレクタでも引ける(SecureTextField はパスワード欄だけ)")
    func S0020() {
        scenario {
            scene(1, "テキスト入力画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_input")
                }.expectation {
                    textIs("#txt_echo_password", "password=")
                }
            }
            scene(2, ".SecureTextField[1] は #field_password に解決される") {
                action {
                    tap(".SecureTextField[1]")
                    type(".SecureTextField[1]", "pw0001")
                }.expectation {
                    textIs("#txt_echo_password", "password=pw0001")
                }
            }
        }
    }
}
