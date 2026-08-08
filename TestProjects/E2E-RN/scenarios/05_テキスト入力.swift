// 05_テキスト入力.swift
// ftester 機能: `type` コマンドと入力値の echo 検証(単一行/パスワード/送信/クリア)。
// **型語彙は予測・未検証**: RN の `TextInput` は iOS では `RCTUITextField`(UITextField の
// サブクラス)、Android では実体が `EditText` になる。`secureTextEntry` は両 OS ともネイティブの
// パスワード欄そのものに立つため、ネイティブ SUT と同じく `.secureTextField` 型で引けると予測している
// (Flutter の `obscureText` のように型で区別できない非対称は起きないはず)。S0020 でこの予測を検証する。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class テキスト入力が正しくechoされること {

    @Test("単一行・パスワードの入力値が echo され送信/クリアが効く")
    func S0010() {
        scenario {
            scene(1, "テキスト入力画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // 起動直後は a11y ツリー完成後もポインタ入力を一時的に取りこぼす実装が
                    // Flutter で実測されている。RN で同じ罠があるかは未検証だが、害の無い
                    // 1往復なので安全側として残す。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_input")
                }.expectation {
                    select("#txt_echo_single").textIs("single=")
                }
            }
            scene(2, "単一行に入力して echo される") {
                action {
                    // Android は input connection が張られるまで ACTION_SET_TEXT を受け付けない
                    // (500「ACTION_SET_TEXT を受け付けないフィールドです」で落ちる)。tap 直後は
                    // 接続確立前のことがあるため、tap と type の間に1往復挟んで待つ
                    // (Flutter で実測した罠。RN でも安全側として残す)。
                    tap("#field_single")
                }.expectation {
                    exist("#field_single")
                }.action {
                    type("#field_single", "hello123")
                }.expectation {
                    select("#txt_echo_single").textIs("single=hello123")
                    select("#txt_echo_length").textIs("len=8")
                }
            }
            scene(3, "単一行の入力値を value* 検証系で確認する") {
                expectation {
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
                    // 空欄側(クリア後等)の valueIsEmpty は書かない: プレースホルダが値として
                    // 読めてしまう OS/フレームワーク差があるため(誤検証を避ける)
                }
            }
            scene(4, "パスワード欄も平文で echo される") {
                action {
                    tap("#field_password")
                }.expectation {
                    exist("#field_password")
                }.action {
                    type("#field_password", "secret42")
                }.expectation {
                    select("#txt_echo_password").textIs("password=secret42")
                }
            }
            scene(5, "送信で submitted に反映される") {
                action {
                    tap("#btn_input_submit")
                }.expectation {
                    select("#txt_input_submitted").textIs("submitted=hello123")
                }
            }
            scene(6, "クリアで全フィールドと submitted が初期化される") {
                action {
                    tap("#btn_input_clear")
                }.expectation {
                    select("#txt_echo_single").textIs("single=")
                    select("#txt_input_submitted").textIs("submitted=-")
                }
            }
        }
    }

    @Test("パスワード欄が secureTextField 型で引ける(予測)")
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
            scene(2, ".secureTextField[1] は #field_password に解決される(予測。ネイティブ SUT の型に揃うはず)") {
                action {
                    tap(".secureTextField[1]")
                    type(".secureTextField[1]", "pw0001")
                }.expectation {
                    select("#txt_echo_password").textIs("password=pw0001")
                }
            }
        }
    }

    @Test("clearInput が入力欄を空にする")
    func S0030() {
        scenario {
            scene(1, "テキスト入力画面を開いて単一行に入力する") {
                condition {
                    launchApp()
                }.expectation {
                    // 起動直後は a11y ツリー完成後もポインタ入力を一時的に取りこぼす実装が
                    // Flutter で実測されている。RN で同じ罠があるかは未検証だが、害の無い
                    // 1往復なので安全側として残す。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の ftester 欠陥」参照。ここで guard を切っても検出器は死なない)。
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_input")
                }.action {
                    // Android は input connection が張られるまで ACTION_SET_TEXT を受け付けない
                    // (S0010 と同じ罠)。tap と type の間に1往復挟んで待つ。
                    tap("#field_single")
                }.expectation {
                    exist("#field_single")
                }.action {
                    type("#field_single", "hello123")
                }.expectation {
                    select("#txt_echo_length").textIs("len=8")
                }
            }
            scene(2, "セレクタ指定の clearInput で単一行が空になる") {
                action {
                    clearInput("#field_single")
                }.expectation {
                    select("#txt_echo_single").textIs("single=")
                    select("#txt_echo_length").textIs("len=0")
                }
            }
            scene(3, "無引数の clearInput はフォーカス中の入力欄(パスワード)を空にする") {
                action {
                    tap("#field_password")
                }.expectation {
                    exist("#field_password")
                }.action {
                    type("#field_password", "secret42")
                }.expectation {
                    select("#txt_echo_password").textIs("password=secret42")
                }.action {
                    clearInput()
                }.expectation {
                    select("#txt_echo_password").textIs("password=")
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
                }.expectation {
                    // 同期の1往復(S0010 scene1 と同じ罠。requireVisible: false の理由もそちら参照)
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_input")
                    tap("#field_single")
                }.expectation {
                    keyboardIsShown()
                }
            }
            scene(2, "hideKeyboard で閉じる(Android のみ。iOS は 501 で未対応: docs/commands.md hideKeyboard 行)") {
                action {
                    android { hideKeyboard() }
                }.expectation {
                    android { keyboardIsNotShown() }
                }
            }
        }
    }
}
