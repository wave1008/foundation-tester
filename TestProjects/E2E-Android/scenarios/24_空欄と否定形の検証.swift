// 24_空欄と否定形の検証.swift
// fleetest 機能: 入力欄の空(valueIsEmpty)・日付書式(valueMatchesDateFormat)・否定形(text*Not)・lastElement。
// 入力欄の値は value* で見る —— 入力欄の text は値ではなく、空欄でプレースホルダを返す SUT
// (CMP iOS・Flutter iOS・RN)と空を返す SUT に割れ、入力後は nil になる(2026-10-02 実測・5 SUT × 両 OS)。
// 空欄の valueIsEmpty は全 SUT で通る(同日実測)。Android のブリッジが空欄に子のヒントを値として写していた
// 不具合(v85 で修正)は value に出たので、ここが見張りになる。

import FTDSL

@TestClass
class 空欄と否定形の検証 {

    @Test("空欄の値は空で、入力クリアの後も空に戻る")
    func S0010() {
        scenario {
            scene(1, "テキスト入力画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_input")
                }.expectation {
                    select("#field_single").valueIsEmpty()
                }
            }
            scene(2, "打ってから入力クリアで消す") {
                action {
                    tap("#field_single")
                    type("#field_single", "abc")
                    tap("#btn_input_clear")
                }.expectation {
                    select("#txt_echo_single").textIs("single=")
                    select("#field_single").valueIsEmpty()
                }
            }
        }
    }

    @Test("日付の書式と否定形の検証が入力値に効く")
    func S0020() {
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
            scene(2, "日付を打つ") {
                action {
                    tap("#field_single")
                    type("#field_single", "2026/10/02")
                }.expectation {
                    select("#field_single").valueMatchesDateFormat("yyyy/MM/dd")
                    select("#txt_echo_single").textStartsWithNot("password=")
                    select("#txt_echo_single").textEndsWithNot("/01")
                    select("#txt_echo_single").textMatchesNot("^single=[a-z]+$")
                }
            }
        }
    }

    @Test("lastElement は直前に掴んだ要素を指す")
    func S0030() {
        scenario {
            scene(1, "テキスト入力画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_input")
                }.expectation {
                    select("#txt_echo_length")
                    lastElement.textIs("len=0")
                }
            }
        }
    }
}
