// 20_値の読み出しと小数タイムアウト.swift
// ftester 機能:
//   ① `exist` の戻り値から**画面の値そのもの**を読む(`.text` / `.id`。docs/design.md §掴んだ要素の値の読み出し)。
//      読んだ値を**次の検証の期待値として使える**ことまでを実機で固定する(これが無いと期待値を
//      シナリオに書き切るしかない)。
//   ② 秒引数が小数(Double)であること(`timeout: 4.5` / `waitSeconds: 2.5`)。
//
// **読む前に値を確定させること**: `.text` は `exist` が照合した時点の値で再取得しない契約なので、
// 更新途中の画面でいきなり読むと古い値を掴む。先に `textIs`/`textContains` で待ってから読む。
// 「掴めなかったら nil」「dry-run では nil」は失敗経路のためここでは見ない
// (Tests/FTDSLTests/FTRuntimeLifecycleTests.swift が持つ)。
// 追加のデバイス往復が起きないことは Tests/FTDSLTests/CommandDispatchTests.swift が持つ。

import Foundation
import FTDSL

@TestClass(app: "com.ftester.e2e")
class 掴んだ要素の値を読んで後段で使えること {

    @Test("画面から採った値をそのまま次の検証に使える")
    func S0010() {
        scenario {
            scene(1, "テキスト入力画面を初期状態で開く") {
                condition {
                    launchApp()
                    tap("#nav_input")
                    tap("#btn_input_clear")
                }.expectation {
                    textIs("#txt_echo_length", "len=0")
                    textIs("#txt_input_submitted", "submitted=-")
                }
            }
            scene(2, "入力した文字数を読み出す(値はアプリが数えるので固定値では通らない)") {
                action {
                    type("#field_single", "readback123")   // 11 文字
                }.expectation {
                    textIs("#txt_echo_length", "len=11")   // 先に確定させる
                    let 文字数 = exist("#txt_echo_length")
                    文字数.text.thisIs("len=11")
                    // .id は「セレクタの綴り」ではなく**実際に解決した要素**の identifier
                    文字数.id.thisIs("txt_echo_length")
                }
            }
            scene(3, "読み出した値を加工して別要素の期待値に使う") {
                action {
                    tap("#btn_input_submit")
                }.expectation {
                    textIs("#txt_input_submitted", "submitted=readback123")   // 先に確定させる
                    let 送信結果 = exist("#txt_input_submitted").text
                    // 画面から採った値だけを使って、別要素(echo)の期待値を組み立てる。
                    // 読み出しが壊れると期待値が "single=" になり必ず落ちる
                    let 入力値 = (送信結果 ?? "").replacingOccurrences(of: "submitted=", with: "")
                    textIs("#txt_echo_single", "single=\(入力値)")
                }
            }
        }
    }

    @Test("秒引数に小数を書ける")
    func S0020() {
        scenario {
            scene(1, "非同期表示画面をリセットして開く") {
                condition {
                    launchApp()
                    tap("#nav_async")
                    tap("#btn_async_reset")
                }.expectation {
                    textIs("#txt_delay_state", "state=idle")
                }
            }
            scene(2, "3秒後表示を timeout: 4.5(小数)で待てる") {
                action {
                    tap("#btn_delay_3")
                }.expectation {
                    exist("#txt_delayed", timeout: 4.5)
                    textIs("#txt_delay_state", "state=done", timeout: 1.5)
                }
            }
            scene(3, "ifCanSelect の waitSeconds も小数で待てる") {
                action {
                    tap("#btn_async_reset")
                    tap("#btn_delay_1")
                    // 1秒後に出る要素を 2.5 秒まで待って拾う(既定の 0 では不成立になる待ち)
                    ifCanSelect("#txt_delayed", waitSeconds: 2.5) {
                        tap("#btn_async_reset")
                    }
                }.expectation {
                    textIs("#txt_delay_state", "state=idle")
                }
            }
        }
    }
}
