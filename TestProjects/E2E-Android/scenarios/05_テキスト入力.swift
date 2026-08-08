// 05_テキスト入力.swift
// ftester 機能: `type` コマンドと入力値の echo 検証(単一行/パスワード/送信/クリア)、`value*` 一式、
// 型セレクタでの入力欄解決、`clearInput`、キーボード表示状態、`pressEnter`・末尾改行の IME アクションを
// まとめて検証する。
// SUT の入力欄は EditText。inputType=textPassword の欄だけ `SecureTextField` になり、
// 複数行(textMultiLine)も `TextField` のまま(iOS ネイティブが TextView になるのと違う)。
// IME アクションの経路は a11y の ACTION_IME_ENTER(既定)/ keyevent 66(フォールバック)で、
// キーイベントはソフトキーボードに吸われて EditText に届かないため、この SUT は a11y 経路が
// 生きていないと落ちる(Compose では気付けない退行を捕まえる唯一の場)。
// 旧シナリオ境界は hideKeyboard() でキーボードを閉じてから tap("#tab_home") → #nav_input を
// 叩き直す形に置き換えてある(直前ブロックが開いたキーボードがタブバーを飲む実害が E2E-iOS の
// xcuitest 実行であったため。Android は `hideKeyboard()` が冪等に使えるので境界の condition
// 冒頭に無条件で置く)。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class テキスト入力が正しくechoされること {

    @Test("単一行・パスワードの入力値が echo され送信/クリアが効く")
    func S0010() {
        scenario {
            scene(1, "05.S0010: 単一行・パスワードの入力値が echo され送信/クリアが効く") {
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
            scene(6, "05.S0020: パスワード欄だけが SecureTextField 型になる") {
                condition {
                    hideKeyboard()
                    tap("#tab_home")
                }.action {
                    tap("#nav_input")
                }.expectation {
                    select("#txt_echo_password").textIs("password=")
                }
            }
            scene(7, ".secureTextField[1] は #field_password に解決される") {
                action {
                    tap(".secureTextField[1]")
                    type(".secureTextField[1]", "pw0001")
                }.expectation {
                    select("#txt_echo_password").textIs("password=pw0001")
                }
            }
            scene(8, "05.S0030: value* 一式で入力欄自体の値を直接検証できる") {
                condition {
                    hideKeyboard()
                    tap("#tab_home")
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
            scene(9, "05.S0040: clearInput が入力欄を空にする") {
                condition {
                    hideKeyboard()
                    tap("#tab_home")
                }.action {
                    tap("#nav_input")
                    tap("#field_single")
                    type("#field_single", "hello123")
                }.expectation {
                    select("#txt_echo_length").textIs("len=8")
                }
            }
            scene(10, "clearInput(#field_single) で単一行欄と長さが空になる") {
                action {
                    clearInput("#field_single")
                }.expectation {
                    select("#txt_echo_single").textIs("single=")
                    select("#txt_echo_length").textIs("len=0")
                }
            }
            scene(11, "clearInput() 引数なしはフォーカス中の欄(パスワード)を空にする") {
                action {
                    tap("#field_password")
                    type("#field_password", "secret42")
                    clearInput()
                }.expectation {
                    select("#txt_echo_password").textIs("password=")
                }
            }
            scene(12, "05.S0050: キーボードの表示状態を検証できる") {
                condition {
                    hideKeyboard()
                    tap("#tab_home")
                }.action {
                    tap("#nav_input")
                    tap("#field_single")
                }.expectation {
                    keyboardIsShown()
                }
            }
            scene(13, "hideKeyboard で閉じる") {
                action {
                    hideKeyboard()
                }.expectation {
                    keyboardIsNotShown()
                }
            }
            scene(14, "18.S0010: pressEnter と type の末尾改行がどちらも IME アクションになる") {
                condition {
                    hideKeyboard()
                    tap("#tab_home")
                }.action {
                    tap("#nav_input")
                }.expectation {
                    select("#txt_ime_action").textIs("ime=0")
                }
            }
            scene(15, "pressEnter で IME アクションが発火する") {
                action {
                    // Android inapp は input connection が張られるまで SET_TEXT を受け付けない(05 と同じ規律)
                    tap("#field_single")
                    type("#field_single", "abc")
                    pressEnter()
                }.expectation {
                    select("#txt_ime_action").textIs("ime=1")
                    select("#txt_echo_single").textIs("single=abc")
                    // len=4 なら改行が文字として入っている
                    select("#txt_echo_length").textIs("len=3")
                }
            }
            scene(16, "一括 type の末尾改行も IME アクションになる") {
                condition {
                    // クリアは ime=0 にも戻す。発火後のフォーカスは SUT ごとに違うので tap し直す
                    tap("#btn_input_clear")
                }.action {
                    tap("#field_single")
                    type("#field_single", "xyz\n")
                }.expectation {
                    select("#txt_ime_action").textIs("ime=1")
                    select("#txt_echo_single").textIs("single=xyz")
                    select("#txt_echo_length").textIs("len=3")
                }
            }
            scene(17, "ロケータ無しの type でも末尾改行が IME アクションになる") {
                condition {
                    tap("#btn_input_clear")
                }.action {
                    // ロケータ無し = フォーカス中の要素へ入力
                    tap("#field_single")
                    type("pqr\n")
                }.expectation {
                    select("#txt_ime_action").textIs("ime=1")
                    select("#txt_echo_single").textIs("single=pqr")
                    select("#txt_echo_length").textIs("len=3")
                }.action {
                    hideKeyboard()
                    tap("#tab_home")
                }
            }
        }
    }
}
