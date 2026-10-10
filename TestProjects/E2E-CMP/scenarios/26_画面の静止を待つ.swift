// 26_画面の静止を待つ.swift
// fleetest 機能: waitForSettle(画面の画素の静止 + 木の同期。docs/commands.md §waitForSettle)。
// flick を settle: false で撃って慣性を残し、waitForSettle で止まりきってから、
// 1 秒置いても先頭に見えている行が変わらない(= 本当に止まった)ことを確かめる。
// CMP は慣性の最後に 1px ずつの這いがあり(最大 650ms 間隔)、木も絵より遅れる = 最も厳しい SUT。
// 時間切れの対照は慣性で作る: E2E はアプリのアニメーションを止めて回す(Android は animator_duration_scale=0・
// iOS は Reduce Motion)ので、進捗バーや回転インジケータは動かず対照にならない。スクロールの慣性はこの設定に左右されない

import FTDSL

@TestClass
class 画面の静止を待てること {

    @Test("flick の慣性が止まりきるまで待ち、静止した画面では throwsException: false でも true を返す")
    func S0010() {
        scenario {
            scene(1, "スクロール画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    exist("#row_01")
                }
            }
            scene(2, "settle: false の flick で慣性を残し、waitForSettle で止まりきるまで待つ") {
                action {
                    flickBottomToTop(scrollFrame: "#list_rows", settle: false)
                    waitForSettle("#list_rows")
                }.expectation {
                    select("#txt_scroll_top").textIsNot("top=row_01")
                }
            }
            scene(3, "1 秒置いても先頭に見えている行が変わらない(慣性の途中で返っていない)") {
                action {
                    writeMemo("topAfterSettle", select("#txt_scroll_top").text ?? "")
                    wait(1)
                }.expectation {
                    readMemo("topAfterSettle").thisIs(select("#txt_scroll_top").text ?? "")
                }
            }
            scene(4, "止まっている画面では窓1回分で返り、throwsException: false でも true を返す") {
                action {
                    writeMemo("settled", waitForSettle(throwsException: false) ? "yes" : "no")
                }.expectation {
                    readMemo("settled").thisIs("yes")
                }
            }
        }
    }

    @Test("慣性の途中で短く打ち切ると時間切れになり、throwsException: false は false を返して先へ進む")
    func S0020() {
        scenario {
            scene(1, "スクロール画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_scroll")
                }.expectation {
                    exist("#row_01")
                }
            }
            scene(2, "settle: false の flick の直後に 0.8 秒だけ待つと、慣性が残っていて false が返る") {
                action {
                    flickBottomToTop(scrollFrame: "#list_rows", settle: false)
                    // 範囲を指定しない(要素を探す時間で 0.8 秒を削らない = 慣性の途中を確実に見る)
                    writeMemo("early", waitForSettle(quietSeconds: 0.3, throwsException: false, waitSeconds: 0.8) ? "yes" : "no")
                }.expectation {
                    readMemo("early").thisIs("no")
                }
            }
            scene(3, "打ち切らずに待てば止まりきる") {
                action {
                    waitForSettle("#list_rows")
                }.expectation {
                    select("#txt_scroll_top").textIsNot("top=row_01")
                }
            }
        }
    }
}
