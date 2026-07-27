// 05_テキスト入力.swift
// ftester 機能: `type` コマンドと入力値の echo 検証(単一行/パスワード/送信/クリア)、
// value* 検証系(valueIs / valueContains / valueIsNotEmpty、exist チェーンの .valueIs)。

import FTDSL

@TestClass(app: "com.ftester.e2e")
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
                    // Android inapp は input connection が張られるまで ACTION_SET_TEXT を受け付けない。
                    // tap で先にフォーカスしてから type する
                    tap("#field_single")
                    type("#field_single", "hello123")
                }.expectation {
                    textIs("#txt_echo_single", "single=hello123")
                    textIs("#txt_echo_length", "len=8")
                    // value* は入力欄自体の値を見る(text* は echo Text)。非空欄なら OS 間で割れない
                    // (空欄の valueIsEmpty は書かない: iOS は空欄の value に placeholder が返るため)
                    valueIs("#field_single", "hello123")
                    valueContains("#field_single", "hello1")
                    valueIsNotEmpty("#field_single")
                    exist("#field_single").valueIs("hello123")
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
}
