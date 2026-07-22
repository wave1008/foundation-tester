// 07_スクロール.swift
// ftester 機能: `scrollTo` による要素到達と、「exist/textIs は非スクロール(現在画面のみ判定)」の
// 契約検証(docs/design.md §10)。
// SUT のリストは **RecyclerView**(型は CollectionView)、行は clickable な ViewGroup(型は `Cell`)。
// 行 id は res/values/ids.xml に静的宣言した row_01..row_40 を onBind で割り当てている
// (View は resource-id を実行時生成できないため。E2EAppAndroid/docs/ui-contract.md)。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class スクロールで折り返し下の要素に到達できること {

    @Test("scrollTo で行リストの末尾まで到達しタップできる")
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
            scene(2, "scrollTo で #row_40 まで送ってからタップ") {
                action {
                    scrollTo("#row_40", maxSwipes: 15)
                    tap("#row_40")
                }.expectation {
                    // #txt_row_selected は固定ヘッダなのでスクロール後も見える
                    textIs("#txt_row_selected", "selected=row_40")
                }
            }
            scene(3, "先頭へで #row_01 が再び見える") {
                action {
                    tap("#btn_scroll_top")
                }.expectation {
                    exist("#row_01")
                }
            }
        }
    }

    @Test("行は Cell 型でラベルセレクタからも引ける")
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
            scene(2, ".Cell=行 03 で引く(行内 TextView にも同じ文字列が出るため型限定が必要)") {
                action {
                    tap(".Cell=行 03")
                }.expectation {
                    textIs("#txt_row_selected", "selected=row_03")
                }
            }
        }
    }

    @Test("exist は非スクロールのため直前に scrollTo が必要")
    func S0030() {
        scenario {
            scene(1, "セレクタ画面を開く") {
                condition {
                    launchApp()
                }.action {
                    tap("#nav_selector")
                }.expectation {
                    textIs("#txt_selector_result", "result=-")
                }
            }
            scene(2, "#txt_offscreen は scrollTo で送らない限り exist で見つからない画面外要素") {
                action {
                    // exist 自体はスクロールしないため、scrollTo で画面内に入れてから確認する。
                    // scrollTo を省いて直接 exist するとタイムアウト失敗する契約の裏返しの検証
                    scrollTo("#txt_offscreen", maxSwipes: 12)
                }.expectation {
                    exist("#txt_offscreen")
                }
            }
        }
    }
}
