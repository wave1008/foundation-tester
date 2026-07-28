// 18_Enterキー.swift
// ftester 機能: `pressEnter()`(IME アクション発火)と、`type` の**末尾改行**が同じ結果になること。
// 観測点は `#txt_ime_action`(`ime=<n>`)= E2EApp/docs/ui-contract.md「テキスト入力画面」の契約。
// **改行が本文に入っていないこと**を `len` で同時に見る(len が増えていたら、IME アクションではなく
// 文字として挿入されている = 退行)。
// **本体を `android { }` で囲む**: Flutter の iOS は IME アクションを駆動する手段が無い
// (2026-07-28 実測。in-app は insertText("\n") が onSubmitted に変換されず、hybrid の xcuitest
// フォールバックも in-app が立てたフォーカスに届かない。E2EAppFlutter/docs/ui-contract.md)。
// **@TestClass の platform で絞らない**のは、この SUT が ios/android 両方の実行プロファイルを持ち、
// platform 指定だと iOS プロファイル実行時に「担当ワーカーがありません」で失敗計上されるため。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class EnterキーでIMEアクションが発火すること {

    @Test("pressEnter と type の末尾改行がどちらも IME アクションになる")
    func S0010() {
        scenario {
            android {
                scene(1, "テキスト入力画面を開く") {
                    condition {
                        launchApp()
                    }.action {
                        tap("#nav_input")
                    }.expectation {
                        textIs("#txt_ime_action", "ime=0")
                    }
                }
                scene(2, "pressEnter で IME アクションが発火する") {
                    action {
                        // input connection が張られるまで SET_TEXT を受け付けない(05 と同じ規律)
                        tap("#field_single")
                        type("#field_single", "abc")
                        pressEnter()
                    }.expectation {
                        textIs("#txt_ime_action", "ime=1")
                        textIs("#txt_echo_single", "single=abc")
                        // len=4 なら改行が文字として入っている
                        textIs("#txt_echo_length", "len=3")
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
                        textIs("#txt_ime_action", "ime=1")
                        textIs("#txt_echo_single", "single=xyz")
                        textIs("#txt_echo_length", "len=3")
                    }
                }
            }
        }
    }
}
