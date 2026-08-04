// 15_型付きセレクタ.swift
// ftester 機能: 型付きセレクタ(Sel)。文字列版と**同じ要素に着地すること**をデバイス実行で固定する。
// ここで使う構文は 04/11 が文字列版で通しているものと同一にしてある(対応する文字列式を各行に併記)。
// 等価性そのもの(FlowLocator が一致すること)は Tests/FTDSLTests/SelTests.swift が持ち、
// この場は「解決してタップ・検証まで届くこと」だけを見る。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class 型付きセレクタが文字列版と同じ要素に着地すること {

    @Test("フォールバック・型限定ラベル・相対セレクタ")
    func S0010() {
        scenario {
            scene(1, "セレクタ画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap(.id("nav_selector"))                       // #nav_selector
                }.expectation {
                    select(.id("txt_selector_result")).textIs("result=-")  // #txt_selector_result
                }
            }
            scene(2, "型限定ラベルの個数と || フォールバック") {
                expectation {
                    countIs(.type(.button).text("項目"), 3)          // .button&&項目
                }.action {
                    // 1つ目は存在しない id。2つ目で解決する
                    tap(.id("btn_alias_old").or(.id("btn_alias_new")))  // #btn_alias_old||#btn_alias_new
                }.expectation {
                    select(.id("txt_selector_result")).textIs("result=alias")
                }
            }
            scene(3, "相対セレクタ(基準が先・近い順の2番目)") {
                action {
                    // #btn_allow:below(.button&&項目&&[2]) と同じ構造(序数は ordinal に正規化される)
                    tap(.id("btn_allow").below(matching: .type(.button).text("項目"), nth: 2))
                }.expectation {
                    select(.id("txt_selector_result")).textIs("result=item2")
                }
            }
        }
    }

    @Test("スコープ・状態フィルタ")
    func S0020() {
        scenario {
            scene(1, "スクロール画面でスコープ内の序数を引く") {
                condition {
                    launchApp()
                    tap(.id("nav_scroll"))
                }.expectation {
                    exist(.id("list_rows").find(.id("row_02")))                    // #list_rows >> #row_02
                    select(.id("list_rows").find(.type(.button).nth(2))).textIs("行 02")   // #list_rows >> .button[2]
                    notExist(.id("list_rows").find(.id("txt_row_selected")))
                }
            }
            scene(2, "checked / enabled のフィルタ") {
                condition {
                    tap(.id("tab_controls"))
                    tap(.id("btn_controls_reset"))
                }.expectation {
                    exist(.id("cb_agree").checked(false))                 // #cb_agree&&checked=false
                    countIs(.type(.button).enabled(false), 2)             // .button&&enabled=false
                }.action {
                    tap(.id("cb_agree"))
                }.expectation {
                    exist(.id("cb_agree").checked())                      // #cb_agree&&checked=true
                    countIs(.type(.button).enabled(false), 1)
                }
            }
        }
    }

    /// Shirates 由来のスクロール別名族は String 版と Sel 版が1対1(design.md §型付きセレクタ)。
    /// 委譲先の方向を取り違えても**コンパイルは通る**ので、実際に届くことをここで固定する
    /// (方向の転記ミス自体は SelScrollVariantDispatchTests がユニットで押さえる)
    @Test("スクロール別名族の Sel 版が文字列版と同じ挙動になる")
    func S0030() {
        scenario {
            scene(1, "スクロール画面を開く") {
                condition {
                    launchApp()
                    tap(.id("nav_scroll"))
                }.expectation {
                    exist(.id("row_01"))
                }
            }
            scene(2, "tapWithScrollDown の Sel 版で折り返し下の行まで送ってタップする") {
                action {
                    tapWithScrollDown(.id("row_40"), maxSwipes: 15)
                }.expectation {
                    // 固定ヘッダなのでスクロール後も見える
                    select(.id("txt_row_selected")).textIs("selected=row_40")
                }
            }
            scene(3, "existWithScrollUp の Sel 版で先頭へ戻りながら確認する") {
                expectation {
                    existWithScrollUp(.id("row_01"), maxSwipes: 15)
                }
            }
            scene(4, "withScrollDown の中でも *WithoutScroll の Sel 版は現在画面だけを見る") {
                action {
                    withScrollDown {
                        // 固定ヘッダは常に現在画面にある = スクロールせずに解決できる
                        existWithoutScroll(.id("txt_row_selected"))
                        tapWithoutScroll(.id("btn_scroll_top"))
                    }
                }.expectation {
                    exist(.id("row_01"))
                }
            }
        }
    }
}
