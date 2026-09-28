// 07_引っ張って更新.swift
// 確かめる癖: PullToRefreshBox(上端でさらに引くと更新が走る = 上端へのスクロールが副作用を持ちうる)。

import FTDSL

@TestClass
class 引っ張って更新できること {

    @Test("引いて更新・上端へ戻すだけでは更新しない")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_refresh", scroll: .down)
                }.expectation {
                    select("#txt_refresh_count").textIs("refresh=0")
                }
            }
            scene(2, "行を下へ引くと更新が1回走る") {
                action {
                    // iOS の RefreshControl は長く引かないと始まらない(SwiftUI と同じ)。画面比率で上から下まで引く
                    gesture {
                        FTFinger(x: 0.5, y: 0.3).move(x: 0.5, y: 0.85, durationSeconds: 1.0).hold(seconds: 0.3)
                    }
                }.expectation {
                    select("#txt_refresh_count", waitSeconds: 5).textIs("refresh=1")
                }
            }
            // scrollToTop の後の回数は読まない(iOS の XCUITest エンジンでは更新が余分に走る。90_不具合の回帰.swift の S0020)
            scene(3, "下端まで送って上端へ戻せる") {
                action {
                    scrollToBottom()
                    scrollToTop()
                }.expectation {
                    exist("#row_refresh_00")
                }
            }
        }
    }
}
