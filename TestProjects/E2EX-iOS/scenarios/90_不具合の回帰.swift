// 90_不具合の回帰.swift
// E2EX-CMP で見つけた fleetest 側の不具合の回帰テスト(2026-09-28)。修正済みのものは緑を保つこと。
// **S0020 の iOS XCUITest だけは未修正で赤**(XCUITest は容器が「まだ送れるか」を申告しないので、
// 端を確かめる送りが上端で「引っ張る」になる)。利用者向けの説明は
// docs/user-docs/reference/writing/ui_component_patterns_ja.md の「現時点の制約」。
// 検索バーへの type の重複(iOS hybrid・修正済み)は 15_検索バー.swift が見る。

import FTDSL

@TestClass
class 修正した不具合が再発しないこと {

    @Test("ページャの scrollToLeftEdge が端まで届く(全エンジン・修正済み)")
    func S0010() {
        scenario {
            scene(1, "最後のページへ") {
                condition {
                    launchApp()
                    tap("#nav_pager")
                }.action {
                    withScrollRight(scrollFrame: "#pager_main") {
                        tap("#btn_page_4")
                    }
                }.expectation {
                    select("#txt_pager_state").textIs("page=4")
                }
            }
            scene(2, "左端まで送ると最初のページのはず") {
                action {
                    scrollToLeftEdge(scrollFrame: "#pager_main")
                }.expectation {
                    select("#txt_pager_state").textIs("page=0")
                }
            }
        }
    }

    @Test("引っ張って更新の一覧で scrollToTop が更新を走らせない(Android は修正済み・iOS XCUITest は未修正)")
    func S0020() {
        scenario {
            scene(1, "下端から上端へ戻しても更新回数は 0 のはず") {
                condition {
                    launchApp()
                    tap("#nav_refresh", scroll: .down)
                }.action {
                    scrollToBottom()
                    scrollToTop()
                    wait(2)
                }.expectation {
                    select("#txt_refresh_count").textIs("refresh=0")
                }
            }
        }
    }

    @Test("Android: 幅いっぱいの行への swipeBy(dxRatio 0.9)が OS の戻るにならない(修正済み)")
    func S0050() {
        scenario {
            scene(1, "3行目を大きく払う") {
                condition {
                    launchApp()
                    tap("#nav_swipe", scroll: .down)
                }.action {
                    swipeBy("#swipe_row_3", dxRatio: -0.9, dyRatio: 0, durationSeconds: 0.3)
                }.expectation {
                    select("#txt_swipe_result").textIs("removed=3")
                }
            }
        }
    }
}
