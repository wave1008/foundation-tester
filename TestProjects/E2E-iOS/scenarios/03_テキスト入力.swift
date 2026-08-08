// 03_テキスト入力.swift
// ftester 機能: `type` コマンドと入力値の echo 検証(単一行/パスワード/型セレクタ/clearInput/
// キーボード表示状態/pressEnter・末尾改行の IME アクション)をまとめて検証する。
// SUT の入力欄は **UIKit の UITextField / UITextView**(SwiftUI TextField ではない)。
// ツリー上の型は TextField / SecureTextField / TextView に分かれるため、型セレクタでも引ける。
// 旧シナリオ境界は tap("#tab_home") でホームへ戻ってから #nav_input を叩き直す形に置き換えてある
// (AppShell はタブ切替で子画面の @State を破棄するため、single/imeCount 等の初期値はこれだけで戻る)。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
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
                    tap("#field_single")
                    type("#field_single", "hello123")
                }.expectation {
                    select("#txt_echo_single").textIs("single=hello123")
                    select("#txt_echo_length").textIs("len=8")
                    // value* は入力欄自身の値を見る(text* は echo Text 側)。
                    // 空欄の valueIsEmpty は書かない: iOS は空欄の value に placeholder
                    // (「単一行」)が返るため空文字と区別できない
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
                    exist("#field_single").valueIs("hello123")
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
            scene(6, "05.S0020: UIKit 入力欄は型セレクタでも引ける(SecureTextField はパスワード欄だけ)") {
                condition {
                    // 直前ブロックが開いたキーボードを閉じてからタブへ戻る(xcuitest は実ヒットテストで
                    // タブバーがキーボードに隠れると tap("#tab_home") がキーボードに飲まれる。
                    // #field_single の Enter は resignFirstResponder = 決定的に閉じる。
                    // 副作用の imeCount はタブ再入の @State 初期化で消える)
                    tap("#field_single")
                    pressEnter()
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
            scene(8, "05.S0030: clearInput が入力欄を空にする") {
                condition {
                    // 直前ブロックが開いたキーボードを閉じてからタブへ戻る(xcuitest は実ヒットテストで
                    // タブバーがキーボードに隠れると tap("#tab_home") がキーボードに飲まれる。
                    // #field_single の Enter は resignFirstResponder = 決定的に閉じる。
                    // 副作用の imeCount はタブ再入の @State 初期化で消える)
                    tap("#field_single")
                    pressEnter()
                    tap("#tab_home")
                }.action {
                    tap("#nav_input")
                    tap("#field_single")
                    type("#field_single", "hello123")
                }.expectation {
                    select("#txt_echo_length").textIs("len=8")
                }
            }
            scene(9, "clearInput(セレクタ)で入力欄と echo が空になる") {
                action {
                    clearInput("#field_single")
                }.expectation {
                    select("#txt_echo_single").textIs("single=")
                    select("#txt_echo_length").textIs("len=0")
                }
            }
            scene(10, "clearInput()(セレクタ省略)はフォーカス中の入力欄に効く") {
                action {
                    tap("#field_password")
                    type("#field_password", "secret42")
                    clearInput()
                }.expectation {
                    select("#txt_echo_password").textIs("password=")
                }
            }
            scene(11, "05.S0040: キーボードの表示状態を検証できる") {
                condition {
                    // 直前ブロックが開いたキーボードを閉じてからタブへ戻る(xcuitest は実ヒットテストで
                    // タブバーがキーボードに隠れると tap("#tab_home") がキーボードに飲まれる。
                    // #field_single の Enter は resignFirstResponder = 決定的に閉じる。
                    // 副作用の imeCount はタブ再入の @State 初期化で消える)
                    tap("#field_single")
                    pressEnter()
                    tap("#tab_home")
                }.action {
                    tap("#nav_input")
                    tap("#field_single")
                }.expectation {
                    keyboardIsShown()
                }
            }
            scene(12, "18.S0010: pressEnter と type の末尾改行がどちらも IME アクションになる") {
                condition {
                    // 直前ブロックが開いたキーボードを閉じてからタブへ戻る(xcuitest は実ヒットテストで
                    // タブバーがキーボードに隠れると tap("#tab_home") がキーボードに飲まれる。
                    // #field_single の Enter は resignFirstResponder = 決定的に閉じる。
                    // 副作用の imeCount はタブ再入の @State 初期化で消える)
                    tap("#field_single")
                    pressEnter()
                    tap("#tab_home")
                }.action {
                    tap("#nav_input")
                }.expectation {
                    select("#txt_ime_action").textIs("ime=0")
                }
            }
            scene(13, "pressEnter で IME アクションが発火する") {
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
            scene(14, "一括 type の末尾改行も IME アクションになる") {
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
            scene(15, "ロケータ無しの type でも末尾改行が IME アクションになる") {
                condition {
                    tap("#btn_input_clear")
                }.action {
                    // ロケータ無し = フォーカス中の要素へ入力。iOS はここも XCUITest 経路へ回る
                    // (ref が無いので attach 済みでないと 409。AppAttachDriver が activate して再試行する)
                    tap("#field_single")
                    type("pqr\n")
                }.expectation {
                    select("#txt_ime_action").textIs("ime=1")
                    select("#txt_echo_single").textIs("single=pqr")
                    select("#txt_echo_length").textIs("len=3")
                }.action {
                    tap("#tab_home")
                }
            }
        }
    }
}
