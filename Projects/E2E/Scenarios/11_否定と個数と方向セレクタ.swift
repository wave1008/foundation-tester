// 11_否定と個数と方向セレクタ.swift
// ftester 機能: notExist / countIs / enabledIsTrue / enabledIsFalse / checkIsON / checkIsOFF / 相対セレクタ `基準:below(...)` `基準:above(...)` /
// 共通ステップ group / クラスの setUp・tearDown の検証。
// 型を使うセレクタは OS 共通で書ける(ブリッジが役割へ正規化するため。ui-contract.md 全体規約)。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class 否定と個数と方向セレクタが正しく動くこと {

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

    @Test("否定・個数・状態アサーションと方向セレクタ・共通ステップ")
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
                    countIs(".button&&項目", 3)
                    countIs("#btn_item_1", 1)
                    countIs("存在しないラベル", 0)
                }
            }
            scene(5, "方向セレクタで同一ラベル群をアンカーで選び分ける") {
                action {
                    // 縦一列に並ぶので上下で選ぶ。`許可` の下にある最初の `項目` = 1 番目
                    tap("#btn_allow:below(.button&&項目)")
                }.expectation {
                    textIs("#txt_selector_result", "result=item1")
                }.action {
                    // `結果クリア` の上にある最も近い `項目` = 3 番目
                    tap("#btn_selector_reset:above(.button&&項目)")
                }.expectation {
                    textIs("#txt_selector_result", "result=item3")
                }
            }
            scene(6, "enabledIsTrue と共通ステップ group") {
                action {
                    group("結果をクリアする") {
                        enabledIsTrue("#btn_selector_reset")
                        tap("#btn_selector_reset")
                    }
                }.expectation {
                    textIs("#txt_selector_result", "result=-")
                }
            }
            scene(7, "enabledIsFalse / enabledIsTrue が要素の操作可否を判定する") {
                condition {
                    tap("#tab_controls")
                    tap("#btn_controls_reset")
                }.expectation {
                    // #btn_always_disabled は常に無効、#btn_toggle_target は #cb_agree 連動(初期 off)
                    enabledIsFalse("#btn_always_disabled")
                    enabledIsFalse("#btn_toggle_target")
                    // 状態は型と独立に取れるので、型が OS で揃わない checkbox でも使える
                    checkIsOFF("#cb_agree")
                }.action {
                    tap("#cb_agree")
                }.expectation {
                    textIs("#txt_cb_agree", "agree=true")
                    checkIsON("#cb_agree")
                    enabledIsTrue("#btn_toggle_target")
                    enabledIsFalse("#btn_always_disabled")
                }.action {
                    tap("#cb_agree")
                }.expectation {
                    checkIsOFF("#cb_agree")
                    enabledIsFalse("#btn_toggle_target")
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
                    exist("#list_rows >> .button[2]").textIs("行 02")
                    // スコープ外(固定ヘッダ)の要素はスコープ内からは解決できない
                    notExist("#list_rows >> #txt_row_selected")
                }
            }
            scene(9, "`&&` 合成・序数つき相対セレクタ・状態フィルタ") {
                condition {
                    tap("#tab_home")
                    tap("#nav_selector")
                }.expectation {
                    // `&&` は id と型の併用にも使える(`.button#btn_allow` と同義の一般形)
                    exist("#btn_allow&&.button")
                    countIs(".button&&項目", 3)
                }.action {
                    // 引数末尾の `&&[n]` は「その方向で近い順の n 番目」。`許可` の下に `項目` が
                    // 3 つ縦に並ぶので 2 番目は item2(並び順は ui-contract.md)
                    tap("#btn_allow:below(.button&&項目&&[2])")
                }.expectation {
                    textIs("#txt_selector_result", "result=item2")
                }
            }
            scene(10, "状態フィルタ(enabled / checked)で候補を絞る") {
                condition {
                    tap("#tab_controls")
                    tap("#btn_controls_reset")
                }.expectation {
                    // **型との AND は SUT 固有**(この SUT の無効ボタンは button だが、View/XML では
                    // clickable になる。他 SUT の 12_セレクタ拡張 は id と併用する形で書いてある)。
                    // disabled の供給源は 2 つだけ(ui-contract.md)
                    countIs(".button&&enabled=false", 2)
                    // checked は Compose が selected trait を出すので iOS でも取れる(SUT 固有。
                    // SwiftUI/UIKit と Flutter(iOS)の checkbox は出さない = ui-contract.md)
                    exist("#cb_agree&&checked=false")
                }.action {
                    tap("#cb_agree")
                }.expectation {
                    exist("#cb_agree&&checked=true")
                    // #btn_toggle_target が有効化されるので disabled は 1 つに減る
                    countIs(".button&&enabled=false", 1)
                }
            }
        }
    }
}
