// 05_テキスト入力.swift
// ftester 機能: `type` コマンドと入力値の echo 検証(単一行/パスワード/送信/クリア)、
// および `value*` 一式(入力欄自体の値の直接検証。肯定・否定の対称形すべて)。
// SUT の入力欄は EditText。inputType=textPassword の欄だけ `SecureTextField` になり、
// 複数行(textMultiLine)も `TextField` のまま(iOS ネイティブが TextView になるのと違う)。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
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
                    select("#txt_echo_single").textIs("single=")
                }
            }
            scene(2, "単一行に入力して echo される") {
                action {
                    // Android は input connection が張られるまで ACTION_SET_TEXT を受け付けない。
                    // tap で先にフォーカスしてから type する
                    tap("#field_single")
                    type("#field_single", "hello123")
                }.expectation {
                    select("#txt_echo_single").textIs("single=hello123")
                    select("#txt_echo_length").textIs("len=8")
                }
            }
            scene(3, "パスワード欄も平文で echo される") {
                action {
                    tap("#field_password")
                    type("#field_password", "secret42")
                }.expectation {
                    select("#txt_echo_password").textIs("password=secret42")
                }
            }
            scene(4, "送信で submitted に反映される") {
                action {
                    tap("#btn_input_submit")
                }.expectation {
                    select("#txt_input_submitted").textIs("submitted=hello123")
                }
            }
            scene(5, "クリアで全フィールドと submitted が初期化される") {
                action {
                    tap("#btn_input_clear")
                }.expectation {
                    select("#txt_echo_single").textIs("single=")
                    select("#txt_input_submitted").textIs("submitted=-")
                }
            }
        }
    }

    @Test("パスワード欄だけが SecureTextField 型になる")
    func S0020() {
        scenario {
            scene(1, "テキスト入力画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_input")
                }.expectation {
                    select("#txt_echo_password").textIs("password=")
                }
            }
            scene(2, ".secureTextField[1] は #field_password に解決される") {
                action {
                    tap(".secureTextField[1]")
                    type(".secureTextField[1]", "pw0001")
                }.expectation {
                    select("#txt_echo_password").textIs("password=pw0001")
                }
            }
        }
    }

    @Test("value* 一式で入力欄自体の値を直接検証できる")
    func S0030() {
        scenario {
            scene(1, "単一行に ASCII を入力した直後の値を検証する") {
                condition {
                    launchApp()
                    tap("#nav_input")
                    tap("#field_single")
                    type("#field_single", "hello123")
                }.expectation {
                    // 空欄状態の valueIsEmpty は検証しない: 空の EditText は hint(プレースホルダ)が
                    // 値として読めてしまうことがあり、意図せず偽陽性/偽陰性になり得るため
                    select("#field_single").valueIs("hello123")
                    select("#field_single").valueContains("hello")
                    select("#field_single").valueIsNotEmpty()
                    // **対称形も同じ値で1回ずつ通す**。判定そのものは AssertKindsTests が固定済みで、
                    // ここで見るのは**ブリッジから来た value** に対して同じ結果が出ることだけ。
                    // valueIsEmpty は書かない(空欄の value にプレースホルダが返る)。
                    // valueMatchesDateFormat は日付を持つ入力欄が SUT に無いので置かない
                    select("#field_single").valueStartsWith("hello")
                    select("#field_single").valueEndsWith("123")
                    select("#field_single").valueMatches("^hello[0-9]+$")
                    select("#field_single").valueIsNot("hello")
                    select("#field_single").valueContainsNot("xyz")
                    select("#field_single").valueStartsWithNot("123")
                    select("#field_single").valueEndsWithNot("hello")
                    select("#field_single").valueMatchesNot("^[0-9]+$")
                    // exist の戻り値にも同じ検証をチェーンできる
                    exist("#field_single").valueIs("hello123")
                }
            }
        }
    }

    @Test("clearInput が入力欄を空にする")
    func S0040() {
        scenario {
            scene(1, "単一行に入力して echo される") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_input")
                    tap("#field_single")
                    type("#field_single", "hello123")
                }.expectation {
                    select("#txt_echo_length").textIs("len=8")
                }
            }
            scene(2, "clearInput(#field_single) で単一行欄と長さが空になる") {
                action {
                    clearInput("#field_single")
                }.expectation {
                    select("#txt_echo_single").textIs("single=")
                    select("#txt_echo_length").textIs("len=0")
                }
            }
            scene(3, "clearInput() 引数なしはフォーカス中の欄(パスワード)を空にする") {
                action {
                    tap("#field_password")
                    type("#field_password", "secret42")
                    clearInput()
                }.expectation {
                    select("#txt_echo_password").textIs("password=")
                }
            }
        }
    }

    @Test("キーボードの表示状態を検証できる")
    func S0050() {
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
            scene(2, "hideKeyboard で閉じる") {
                action {
                    hideKeyboard()
                }.expectation {
                    keyboardIsNotShown()
                }
            }
        }
    }
}
