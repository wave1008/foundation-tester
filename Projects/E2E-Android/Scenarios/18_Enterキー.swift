// 18_Enterキー.swift
// ftester 機能: `pressEnter()`(IME アクション発火)と、`type` の**末尾改行**が同じ結果になること。
// 観測点は `#txt_ime_action`(`ime=<n>`)= E2EAppCMP/docs/ui-contract.md「テキスト入力画面」の契約。
// **改行が本文に入っていないこと**を `len` で同時に見る(len が増えていたら、IME アクションではなく
// 文字として挿入されている = 退行)。
// 経路は a11y の ACTION_IME_ENTER(既定)/ keyevent 66(フォールバック)で、届く actionId が違う
// (E2EAppAndroid/docs/ui-contract.md)。**キーイベントはソフトキーボードに吸われて EditText に
// 届かない**ため、この SUT は a11y 経路が生きていないと落ちる ―― Compose では気付けない退行を
// 捕まえる唯一の場。`ime=1` の検証は数え落としと二重カウントの両方を見る。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class EnterキーでIMEアクションが発火すること {

    @Test("pressEnter と type の末尾改行がどちらも IME アクションになる")
    func S0010() {
        scenario {
            scene(1, "テキスト入力画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_input")
                }.expectation {
                    select("#txt_ime_action").textIs("ime=0")
                }
            }
            scene(2, "pressEnter で IME アクションが発火する") {
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
            scene(3, "一括 type の末尾改行も IME アクションになる") {
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
            scene(4, "ロケータ無しの type でも末尾改行が IME アクションになる") {
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
                }
            }
        }
    }
}
