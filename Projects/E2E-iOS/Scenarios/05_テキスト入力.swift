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
                    // value* は入力欄自身の値を見る(text* は echo Text 側)。
                    // 空欄の valueIsEmpty は書かない: iOS は空欄の value に placeholder
                    // (「単一行」)が返るため空文字と区別できない
                    valueIs("#field_single", "hello123")
                    valueContains("#field_single", "hello")
                    valueIsNotEmpty("#field_single")
                    // **対称形も同じ値で1回ずつ通す**。判定そのものは AssertKindsTests が固定済みで、
                    // ここで見るのは**ブリッジから来た value** に対して同じ結果が出ることだけ。
                    // valueIsEmpty は書かない(空欄の value にプレースホルダが返る)。
                    // valueMatchesDateFormat は日付を持つ入力欄が SUT に無いので置かない
                    valueStartsWith("#field_single", "hello")
                    valueEndsWith("#field_single", "123")
                    valueMatches("#field_single", "^hello[0-9]+$")
                    valueIsNot("#field_single", "hello")
                    valueContainsNot("#field_single", "xyz")
                    valueStartsWithNot("#field_single", "123")
                    valueEndsWithNot("#field_single", "hello")
                    valueMatchesNot("#field_single", "^[0-9]+$")
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
            scene(2, ".secureTextField[1] は #field_password に解決される") {
                action {
                    tap(".secureTextField[1]")
                    type(".secureTextField[1]", "pw0001")
                }.expectation {
                    textIs("#txt_echo_password", "password=pw0001")
                }
            }
        }
    }

    @Test("clearInput が入力欄を空にする")
    func S0030() {
        scenario {
            scene(1, "単一行に入力する") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_input")
                    tap("#field_single")
                    type("#field_single", "hello123")
                }.expectation {
                    textIs("#txt_echo_length", "len=8")
                }
            }
            scene(2, "clearInput(セレクタ)で入力欄と echo が空になる") {
                action {
                    clearInput("#field_single")
                }.expectation {
                    textIs("#txt_echo_single", "single=")
                    textIs("#txt_echo_length", "len=0")
                }
            }
            scene(3, "clearInput()(セレクタ省略)はフォーカス中の入力欄に効く") {
                action {
                    tap("#field_password")
                    type("#field_password", "secret42")
                    clearInput()
                }.expectation {
                    textIs("#txt_echo_password", "password=")
                }
            }
        }
    }

    @Test("キーボードの表示状態を検証できる")
    func S0040() {
        scenario {
            scene(1, "入力欄をタップするとキーボードが出る") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_input")
                    tap("#field_single")
                }.expectation {
                    keyboardIsShown()
                }
            }
        }
    }
}
