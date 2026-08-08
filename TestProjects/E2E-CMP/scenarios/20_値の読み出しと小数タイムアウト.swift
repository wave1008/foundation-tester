// 20_値の読み出しと小数タイムアウト.swift
// ftester 機能: `exist` の戻り値から**画面の値そのもの**を読む(`.text` / `.id`。
// docs/design.md §掴んだ要素の値の読み出し)。読んだ値を**次の検証の期待値として使える**ことまで
// をデバイス実行で固定する(これが無いと期待値をシナリオに書き切るしかない)。
//
// **読む前に値を確定させること**: `.text` は `exist` が照合した時点の値で再取得しない契約なので、
// 更新途中の画面でいきなり読むと古い値を掴む。先に `textIs`/`textContains` で待ってから読む。
// 「掴めなかったら nil」「dry-run では nil」は失敗経路のためここでは見ない
// (Tests/FTDSLTests/FTRuntimeLifecycleTests.swift が持つ)。
// 追加のデバイス往復が起きないことは Tests/FTDSLTests/CommandDispatchTests.swift が持つ。
//
// **秒引数の小数指定(timeout: 4.5 / waitSeconds: 2.5)の検証(旧 S0020)は
// 08_待機とタイムアウト.swift(08.S0010→21.S0010→20.S0020 の統合クラスタ)へ移設した**。
// この S0010 自体はテキスト入力画面が対象で、入力系クラスタ(05/18)は境界のキーボード確実消去に
// iOS 側の決定的な手段が無いため統合を見送っている(E2EAppCMP は IME アクション発火後もフォーカス・
// キーボードを保持する。ui-contract.md「テキスト入力画面」の IME アクション節)。統合せず単独 @Test のまま。

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
                    select("#txt_echo_length").textIs("len=0")
                    select("#txt_input_submitted").textIs("submitted=-")
                }
            }
            scene(2, "入力した文字数を読み出す(値はアプリが数えるので固定値では通らない)") {
                action {
                    type("#field_single", "readback123")   // 11 文字
                }.expectation {
                    select("#txt_echo_length").textIs("len=11")   // 先に確定させる
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
                    select("#txt_input_submitted").textIs("submitted=readback123")   // 先に確定させる
                    let 送信結果 = exist("#txt_input_submitted").text
                    // 画面から採った値だけを使って、別要素(echo)の期待値を組み立てる。
                    // 読み出しが壊れると期待値が "single=" になり必ず落ちる
                    let 入力値 = (送信結果 ?? "").replacingOccurrences(of: "submitted=", with: "")
                    select("#txt_echo_single").textIs("single=\(入力値)")
                }
            }
        }
    }
}
