// 03_テキスト入力.swift
// fleetest 機能: `type` コマンドと入力値の echo 検証(単一行/パスワード/送信/クリア)、
// value* 検証系(valueIs 以下の対称形一式と、exist チェーンの .valueIs)。

import FTDSL

@TestClass
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
                    // Android inapp は input connection が張られるまで ACTION_SET_TEXT を受け付けない。
                    // tap で先にフォーカスしてから type する
                    tap("#field_single")
                    type("#field_single", "hello123")
                }.expectation {
                    select("#txt_echo_single").textIs("single=hello123")
                    select("#txt_echo_length").textIs("len=8")
                    // value* は入力欄自体の値を見る(text* は echo Text)。非空欄なら OS 間で割れない
                    // (空欄の valueIsEmpty は書かない: iOS は空欄の value に placeholder が返るため)
                    select("#field_single").valueIs("hello123")
                    select("#field_single").valueContains("hello1")
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
                    // Android: パスワード欄のキーボードは背の低い実機(Pixel 4a 851dp)で窓を
                    // 2340→1267px に縮め、送信/クリアが木から消える(Pixel 9 の 923dp では消えない)。
                    // 容器はスクロールしないので scroll: では届かず、閉じてから撃つ
                    android { hideKeyboard() }
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

    @Test("clearInput が入力欄を空にする")
    func S0020() {
        scenario {
            scene(1, "単一行に入力する") {
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
                    type("#field_password", "secret42")
                    clearInput()
                }.expectation {
                    select("#txt_echo_password").textIs("password=")
                }
            }
        }
    }

    @Test("type(replace:) が既存値を置き換える")
    func S0040() {
        scenario {
            scene(1, "セレクタ指定の type(replace:) は追記せず置き換える") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_input")
                    tap("#field_single")
                    type("#field_single", "abc")
                    type("#field_single", "xyz", replace: true)
                }.expectation {
                    // 追記なら single=abcxyz / len=6 になる
                    select("#txt_echo_single").textIs("single=xyz")
                    select("#txt_echo_length").textIs("len=3")
                }
            }
            scene(2, "ロケータなしの type(replace:) はフォーカス中の入力欄を置き換える") {
                action {
                    tap("#field_password")
                    type("#field_password", "secret42")
                    type("plain9", replace: true)
                }.expectation {
                    select("#txt_echo_password").textIs("password=plain9")
                }
            }
        }
    }

    @Test("キーボードの表示状態を検証できる")
    func S0030() {
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
            scene(2, "hideKeyboard で閉じる(Android のみ。iOS は 501 で未対応: docs/commands.md hideKeyboard 行)") {
                action {
                    android { hideKeyboard() }
                }.expectation {
                    android { keyboardIsNotShown() }
                }
            }
        }
    }

    /// **空白だけの replace の陽性対照**(2026-08-31・実機 iPhone 13 の Compose で踏んだ形):
    /// Compose の欄では空白だけの内容が a11y の値に載らず、ランナーの `/clear` が「もう空」と誤認し、
    /// `/type` の読み返しが clear 前の控えを期待に足して再送していた(`   モバイル   `)。
    /// ランナーは「空に見える」欄にも短い削除バーストを送り、`/clear` 後の控えを空にし、読み返しは
    /// 空白だけの差を検証不能として再送しない。どれか1つが崩れると `xyz` の前後に旧値や空白が残る
    @Test("空白だけで置き換えた後も replace が旧値を残さない")
    func S0050() {
        scenario {
            scene(1, "入力画面を開いて値を入れる") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_input")
                    tap("#field_single")
                    type("#field_single", "hello")
                }.expectation {
                    select("#txt_echo_single").textIs("single=hello")
                }
            }
            scene(2, "空白だけで置き換える(値は見えないことがある)") {
                action {
                    type("#field_single", "   ", replace: true)
                }.expectation {
                    select("#txt_echo_single").textContainsNot("hello")
                }
            }
            scene(3, "そのまま文字で置き換えると前後に何も残らない") {
                action {
                    type("#field_single", "xyz", replace: true)
                }.expectation {
                    select("#txt_echo_single").textIs("single=xyz")
                    select("#txt_echo_length").textIs("len=3")
                }
            }
        }
    }
}
