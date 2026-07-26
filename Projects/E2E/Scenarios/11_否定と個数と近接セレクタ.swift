// 11_否定と個数と近接セレクタ.swift
// ftester 機能: notExist / countIs / isEnabled / isDisabled / 近接セレクタ `:near(...)` /
// 共通ステップ group / クラスの setUp・tearDown の検証。
// 型を使うセレクタは OS で型名が違う(Compose の Button は iOS=Button / Android=Cell)ため
// ios {} / android {} で分ける(ui-contract.md 全体規約)。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class 否定と個数と近接セレクタが正しく動くこと {

    // 各 @Test の前に自動実行される。セッションカウンタを1つ進めておき、
    // 「本体より前に走った」ことを scene 1 で観測する
    func setUp() {
        launchApp()
        tap("#nav_lifecycle")
        tap("#btn_session_inc")
    }

    // 各 @Test の後に自動実行される(失敗後でも実行される契約)
    func tearDown() {
        tap("#tab_home")
    }

    @Test("否定・個数・状態アサーションと近接セレクタ・共通ステップ")
    func S0010() {
        scenario {
            scene(1, "setUp が本体より前に実行されている") {
                expectation {
                    textIs("#txt_screen_title", "ライフサイクル")
                    textIs("#txt_session_count", "session=1")
                }
            }
            scene(2, "notExist は未配置の要素を即座に不在と判定し、消えるまで待つ") {
                condition {
                    tap("#tab_home")
                    tap("#nav_async")
                }.expectation {
                    // 待機中は「非表示」ではなくツリーに未配置(ui-contract.md)
                    notExist("#txt_delayed")
                }.action {
                    tap("#btn_delay_1")
                }.expectation {
                    exist("#txt_delayed")
                }.action {
                    tap("#btn_async_reset")
                }.expectation {
                    notExist("#txt_delayed")
                    textIs("#txt_delay_state", "state=idle")
                }
            }
            scene(3, "notExist でダイアログが閉じたことを検証する") {
                condition {
                    tap("#btn_back")
                    tap("#nav_dialog")
                }.action {
                    tap("#btn_show_dialog")
                }.expectation {
                    exist("#txt_dialog_title")
                }.action {
                    tap("#btn_dialog_ok")
                }.expectation {
                    notExist("#txt_dialog_title")
                    textIs("#txt_dialog_result", "dialog=ok")
                }
            }
            scene(4, "countIs で同一ラベル要素の個数を数える") {
                condition {
                    tap("#btn_back")
                    tap("#nav_selector")
                }.expectation {
                    // 同一ラベル `項目` のボタンは3つ(内側の Text と混ざらないよう型で絞る)
                    ios { countIs(".Button=項目", 3) }
                    android { countIs(".Cell=項目", 3) }
                    countIs("#btn_item_1", 1)
                    countIs("存在しないラベル", 0)
                }
            }
            scene(5, "近接セレクタで同一ラベル群をアンカーで選び分ける") {
                action {
                    ios { tap(".Button=項目:near(#btn_allow)") }
                    android { tap(".Cell=項目:near(#btn_allow)") }
                }.expectation {
                    // `許可` に最も近い `項目` は 1 番目(ui-contract.md の並び順)
                    textIs("#txt_selector_result", "result=item1")
                }.action {
                    ios { tap(".Button=項目:near(#btn_selector_reset)") }
                    android { tap(".Cell=項目:near(#btn_selector_reset)") }
                }.expectation {
                    textIs("#txt_selector_result", "result=item3")
                }
            }
            scene(6, "isEnabled と共通ステップ group") {
                action {
                    group("結果をクリアする") {
                        isEnabled("#btn_selector_reset")
                        tap("#btn_selector_reset")
                    }
                }.expectation {
                    textIs("#txt_selector_result", "result=-")
                }
            }
            scene(7, "isDisabled / isEnabled が要素の操作可否を判定する") {
                condition {
                    tap("#tab_controls")
                    tap("#btn_controls_reset")
                }.expectation {
                    // #btn_always_disabled は常に無効、#btn_toggle_target は #cb_agree 連動(初期 off)
                    isDisabled("#btn_always_disabled")
                    isDisabled("#btn_toggle_target")
                }.action {
                    tap("#cb_agree")
                }.expectation {
                    textIs("#txt_cb_agree", "agree=true")
                    isEnabled("#btn_toggle_target")
                    isDisabled("#btn_always_disabled")
                }.action {
                    tap("#cb_agree")
                }.expectation {
                    isDisabled("#btn_toggle_target")
                }
            }
            scene(8, "スコープ(>>)は祖先の子孫だけを対象にする") {
                condition {
                    tap("#tab_home")
                    tap("#nav_scroll")
                }.expectation {
                    // #list_rows は行を包む容器(ui-contract.md)。スコープはその子孫だけを見る
                    exist("#list_rows >> #row_02")
                    countIs("#list_rows >> #row_02", 1)
                    // 序数もスコープ内で数える(容器の外の同型要素に影響されない)
                    ios { exist("#list_rows >> .Button[2]").textIs("行 02") }
                    android { exist("#list_rows >> .Cell[2]").textIs("行 02") }
                    // スコープ外(固定ヘッダ)の要素はスコープ内からは解決できない
                    notExist("#list_rows >> #txt_row_selected")
                }
            }
        }
    }
}
