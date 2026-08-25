// 03_テキスト入力.swift
// fleetest 機能: `type` コマンドと入力値の echo 検証(単一行/パスワード/型セレクタ/clearInput/
// キーボード表示状態/pressEnter・末尾改行の IME アクション)をまとめて検証する
// (E2E-iOS 05_テキスト入力.swift の移植。旧 05.S0010〜S0040 + 18 の統合)。
// **型語彙は予測・未検証**: RN の `TextInput` は iOS では `RCTUITextField`(UITextField の
// サブクラス)、Android では実体が `EditText` になる。`secureTextEntry` は両 OS ともネイティブの
// パスワード欄そのものに立つため、ネイティブ SUT と同じく `.secureTextField` 型で引けると予測している
// (Flutter の `obscureText` のように型で区別できない非対称は起きないはず)。S0020 でこの予測を検証する。
// 旧シナリオ境界は tap("#tab_home") でホームへ戻ってから #nav_input を叩き直す形に置き換えてある
// (AppShell はタブ切替で homeChild を null に戻し子画面をアンマウントするため、single/imeCount 等の
// 初期値はこれだけで戻る)。**境界でも起動直後の同期用 exist(#txt_home_marker) は元の scene1 に
// あった場合だけ維持する**(旧 S0020/18 は元々このマーカーを持たない)。
// **キーボードを閉じてから境界へ渡る**(xcuitest は実ヒットテストで、タブバーがキーボードに
// 隠れると tap("#tab_home") がキーボードに飲まれる。E2E-iOS で実害)。
// Android は `hideKeyboard()`(iOS は 501 未対応。S0040 参照)。iOS は #field_single が単一行
// TextInput で `blurOnSubmit` 明示なし = RN の既定 `submitBehavior` は非 multiline で
// `blurAndSubmit`(node_modules/react-native/Libraries/Components/TextInput/TextInput.js)。
// pressEnter が textFieldShouldReturn: を発火させ確実にフォーカス解除する(18 の実測どおり)。
// 副作用の imeCount はタブ再入の @State 初期化で消える。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class テキスト入力が正しくechoされること {

    @Test("単一行・パスワードの入力値が echo され送信/クリアが効く・secureTextField 型(予測)・clearInput・キーボード表示状態・pressEnter/末尾改行の IME アクション")
    func S0010() {
        scenario {
            scene(1, "05.S0010: 単一行・パスワードの入力値が echo され送信/クリアが効く") {
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
            scene(7, "05.S0020: パスワード欄が secureTextField 型で引ける(予測)") {
                condition {
                    // 直前ブロックが開いたキーボードを閉じてからタブへ戻る(xcuitest は実ヒットテストで
                    // タブバーがキーボードに隠れると tap("#tab_home") がキーボードに飲まれる。
                    // Android は hideKeyboard()、iOS は #field_single の blurOnSubmit 既定
                    // (blurAndSubmit)を pressEnter で発火させて閉じる。副作用の imeCount は
                    // タブ再入の @State 初期化で消える)
                    ios {
                        tap("#field_single")
                        pressEnter()
                    }
                    android {
                        hideKeyboard()
                    }
                    tap("#tab_home")
                }.action {
                    tap("#nav_input")
                }.expectation {
                    select("#txt_echo_password").textIs("password=")
                }
            }
            scene(8, ".secureTextField[1] は #field_password に解決される(予測。ネイティブ SUT の型に揃うはず)") {
                action {
                    tap(".secureTextField[1]")
                    type(".secureTextField[1]", "pw0001")
                }.expectation {
                    select("#txt_echo_password").textIs("password=pw0001")
                }
            }
            scene(9, "05.S0030: clearInput が入力欄を空にする") {
                condition {
                    // 直前ブロックが開いたキーボードを閉じてからタブへ戻る(理由は scene 7 と同じ)
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
            scene(10, "セレクタ指定の clearInput で単一行が空になる") {
                action {
                    clearInput("#field_single")
                }.expectation {
                    select("#txt_echo_single").textIs("single=")
                    select("#txt_echo_length").textIs("len=0")
                }
            }
            scene(11, "無引数の clearInput はフォーカス中の入力欄(パスワード)を空にする") {
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
            scene(12, "05.S0040: キーボードの表示状態を検証できる") {
                condition {
                    // 直前ブロックが開いたキーボードを閉じてからタブへ戻る(理由は scene 7 と同じ)
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
            scene(13, "hideKeyboard で閉じる(Android のみ。iOS は 501 で未対応: docs/commands.md hideKeyboard 行)") {
                action {
                    android { hideKeyboard() }
                }.expectation {
                    android { keyboardIsNotShown() }
                }
            }
            scene(14, "18.S0010: pressEnter と type の末尾改行がどちらも IME アクションになる") {
                condition {
                    // 直前ブロックが開いたキーボードを閉じてからタブへ戻る(理由は scene 7 と同じ。
                    // Android は scene 13 の hideKeyboard で既に閉じているが、iOS 側は開いたままなので
                    // ここでも同じ手順を踏む)
                    ios {
                        tap("#field_single")
                        pressEnter()
                    }
                    android {
                        hideKeyboard()
                    }
                    tap("#tab_home")
                }.action {
                    tap("#nav_input")
                }.expectation {
                    select("#txt_ime_action").textIs("ime=0")
                }
            }
            scene(15, "pressEnter で IME アクションが発火する") {
                action {
                    // input connection が張られるまで SET_TEXT を受け付けない(05 と同じ規律)
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

    /// **RN New Architecture の regression 検知器**(E2EAppRN/docs/ui-contract.md §NewArch 追跡)。
    /// facebook/react-native#38709 = New Arch で TextInput の testID が本体でなく親ラッパーに
    /// 付く退行。`.型#id` は**同一要素**に型と id の両方を要求するので、id が親(other)へ
    /// 移ると解決できなくなり、ここが赤くなる。RN のバージョン更新後は必ずこのシナリオを見る
    @Test("TextInput の testID が入力欄本体に付いている(NewArch #38709 の検知器)")
    func S0050() {
        scenario {
            scene(1, "型と id が同一要素で解決できる") {
                condition {
                    launchApp()
                }.expectation {
                    exist("#txt_home_marker", requireVisible: false)
                }.action {
                    tap("#nav_input")
                }.expectation {
                    exist(".textField#field_single")
                    exist(".secureTextField#field_password")
                    ios { exist(".textView#field_multiline") }
                    android { exist(".textField#field_multiline") }
                }
            }
        }
    }
}
