// 26_画面の静止を待つ.swift
// fleetest 機能: waitForSettle(画面の画素の静止 + 木の同期。docs/commands.md §waitForSettle)。
// flick を settle: false で撃って慣性を残し、waitForSettle で止まりきってから、
// 1 秒置いても先頭に見えている行が変わらない(= 本当に止まった)ことを確かめる。
// SwiftUI の慣性は最長 3.7 秒(UIScrollView の減速)。同じ内容の CMP 版(E2E-CMP/26)が最も厳しい条件を受け持つ。
// 時間切れの対照はティッカー(#txt_ticker。100ms ごとに文言が変わる)で作る: E2E はアプリのアニメーションを止めて回す
// (Android は animator_duration_scale=0・iOS は Reduce Motion)ので進捗バー等は対照にならず、慣性は長さが保証されない

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

    @Test("ティッカーが動いている間は静止せず、throwsException: false は false を返して先へ進む。止めれば静止する")
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
            scene(2, "ティッカーを動かしている間は静止しないので、時間内に止まらず false が返る") {
                action {
                    tap("#btn_ticker_toggle")
                    // 窓 0.5 秒・上限 1.5 秒 = 窓 3 回ぶん。ティッカーは 100ms ごとに変わるので静止は成立しない
                    writeMemo("early", waitForSettle(quietSeconds: 0.5, throwsException: false, waitSeconds: 1.5) ? "yes" : "no")
                }.expectation {
                    readMemo("early").thisIs("no")
                }
            }
            scene(3, "止めれば静止する") {
                action {
                    tap("#btn_ticker_toggle")
                    waitForSettle()
                }.expectation {
                    select("#txt_ticker").textIsNot("ticker=0")
                }
            }
        }
    }
}
