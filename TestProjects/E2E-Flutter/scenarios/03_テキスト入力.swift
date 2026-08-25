// 03_テキスト入力.swift
// fleetest 機能: `type` コマンドと入力値の echo 検証(単一行/パスワード/送信/クリア/clearInput/
// キーボード表示状態/pressEnter・末尾改行の IME アクション)をまとめて検証する
// (旧: 05_テキスト入力 の S0010〜S0030 / 18_Enterキー)。
// Flutter の `obscureText: true` は **`SecureTextField` にならない**(iOS/Android とも `TextField`)。
// ネイティブ SUT のように型でパスワード欄を区別できないため、`#id` で引く。
// 旧シナリオ境界は tap("#tab_home") でホームへ戻ってから #nav_input を叩き直す形に置き換えてある
// (AppShell はタブ切替で子画面の State を破棄するため、single/imeCount 等の初期値はこれだけで戻る)。
// **各境界の直前でキーボードを閉じる**: Flutter の `#field_single` は `TextInputAction.search`
// (非 multiline)なので、Flutter framework の既定実装(`EditableText.performAction` →
// `_finalizeEditing(shouldUnfocus: true)` → `focusNode.unfocus()`)が Enter で確実にフォーカスを
// 外す(Flutter SDK `editable_text.dart` で確認済み。docs/commands.md の
// 「iOS で閉じたいときは pressEnter() を使う(単一行の欄なら閉じる)」と一致)。
// iOS = tap(#field_single) + pressEnter() / Android = hideKeyboard()(冪等: 出ているときだけ効く)。
// 閉じずに #tab_home を叩むと、キーボードに隠れたタブバーへのタップが飲まれる事故が
// 他 SUT(E2E-iOS)で実害化しているため、Flutter でも同じ型で防いでおく。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class テキスト入力が正しくechoされること {

    @Test("単一行・パスワードの入力値が echo され送信/クリアが効く・clearInput・キーボード表示状態・pressEnter/末尾改行の IME アクション")
    func S0010() {
        scenario {
            scene(1, "05.S0010: 単一行・パスワードの入力値が echo され送信/クリアが効く") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms、a11y ツリーは完成しているのに**ポインタ入力を
                    // 取りこぼす**ことがある(初回タップが成功扱いのまま黙って無反応になる。
                    // Android で実測)。ここで1往復させ、着地を確認してから操作する。
                    //
                    // requireVisible: false = これは可視性の**検証**ではなく同期のための1往復。
                    // FM はホスト全体で直列化(約1回/秒)されるため、全 launchApp で FM を
                    // 呼ぶとコストだけが乗る。**可視性の検証と、occlusion-guard の誤判定を
                    // 検出する役目は 01_起動と画面遷移 が既定(true)のまま担う**
                    // (README「既知の fleetest 欠陥」参照。ここで guard を切っても検出器は死なない)。
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
                    // (500「ACTION_SET_TEXT を受け付けないフィールドです」で落ちる)。Flutter は
                    // この接続確立が tap 応答より遅れるため、tap と type の間に1往復挟んで待つ。
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
            scene(7, "05.S0020: clearInput が入力欄を空にする") {
                condition {
                    // 直前ブロックが開いたキーボードを閉じてからタブへ戻る(理由はファイル冒頭コメント参照)
                    ios {
                        tap("#field_single")
                        pressEnter()
                    }
                    android {
                        hideKeyboard()
                    }
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_input")
                }.action {
                    // Android は input connection が張られるまで ACTION_SET_TEXT を受け付けない
                    // (scene 2 と同じ罠)。tap と type の間に1往復挟んで待つ。
                    tap("#field_single")
                }.expectation {
                    exist("#field_single")
                }.action {
                    type("#field_single", "hello123")
                }.expectation {
                    select("#txt_echo_length").textIs("len=8")
                }
            }
            scene(8, "セレクタ指定の clearInput で単一行が空になる") {
                action {
                    clearInput("#field_single")
                }.expectation {
                    select("#txt_echo_single").textIs("single=")
                    select("#txt_echo_length").textIs("len=0")
                }
            }
            scene(9, "無引数の clearInput はフォーカス中の入力欄(パスワード)を空にする") {
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
            scene(10, "05.S0030: キーボードの表示状態を検証できる") {
                condition {
                    // 直前ブロックが開いたキーボードを閉じてからタブへ戻る(理由はファイル冒頭コメント参照)
                    ios {
                        tap("#field_single")
                        pressEnter()
                    }
                    android {
                        hideKeyboard()
                    }
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_input")
                    tap("#field_single")
                }.expectation {
                    keyboardIsShown()
                }
            }
            scene(11, "hideKeyboard で閉じる(Android のみ。iOS は 501 で未対応: docs/commands.md hideKeyboard 行)") {
                action {
                    android { hideKeyboard() }
                }.expectation {
                    android { keyboardIsNotShown() }
                }
            }
            scene(12, "18.S0010: pressEnter と type の末尾改行がどちらも IME アクションになる") {
                condition {
                    // 直前ブロックが開いたキーボードを閉じてからタブへ戻る(理由はファイル冒頭コメント参照)
                    ios {
                        tap("#field_single")
                        pressEnter()
                    }
                    android {
                        hideKeyboard()
                    }
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_input")
                }.expectation {
                    select("#txt_ime_action").textIs("ime=0")
                }
            }
            scene(13, "pressEnter で IME アクションが発火する") {
                action {
                    // input connection が張られるまで SET_TEXT を受け付けない(scene 2 と同じ規律)
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
            scene(16, "type(replace:) が追記せず置き換える") {
                condition {
                    tap("#nav_input")
                    tap("#btn_input_clear")
                }.action {
                    tap("#field_single")
                    type("#field_single", "abc")
                    // Flutter の iOS は clear が in-app では効かず XCUITest 経路へ落ちる
                    // (docs/shirates-parity.md の clearInput 行)。replace もその経路を通る
                    type("#field_single", "xyz", replace: true)
                }.expectation {
                    // 追記なら single=abcxyz / len=6 になる
                    select("#txt_echo_single").textIs("single=xyz")
                    select("#txt_echo_length").textIs("len=3")
                }
                // **末尾にタブ操作を置かない**: 末尾改行の無い type はキーボードを開いたままにするので、
                // Android では InputMethod ウィンドウが下端のタブを覆って解決できない
            }
        }
    }
}
