// 18_Enterキー.swift
// ftester 機能: `pressEnter()`(IME アクション発火)と、`type` の**末尾改行**が同じ結果になること。
// 観測点は `#txt_ime_action`(`ime=<n>`)= E2EAppCMP/docs/ui-contract.md「テキスト入力画面」の契約。
// **改行が本文に入っていないこと**を `len` で同時に見る(len が増えていたら、IME アクションではなく
// 文字として挿入されている = 退行)。
// この SUT は Compose なので、経路は iOS inapp=IntermediateTextInputUIView への insertText("\n")
// (Compose は**呼び出し単位で "\n" 完全一致のときだけ** IME アクションに変換する。この条件を
// 満たすためにホスト側が type の末尾改行を分離送信している)/ iOS xcuitest=typeText("\n") /
// Android=keyevent 66。**inapp の分離送信を踏む主 SUT**。

import FTDSL

@TestClass(app: "com.ftester.e2e")
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
