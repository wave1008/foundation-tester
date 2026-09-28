// 91_不具合の回帰_Android.swift
// 90_不具合の回帰.swift の S0020 を Android だけで回す(iOS は Flutter 側の制約で @Draft のため、
// OS を宣言できるのがクラス単位だけなのでここへ分けた)。

import FTDSL

@TestClass(platform: "android")
class 修正した不具合が再発しないこと_Android {

    @Test("引っ張って更新の一覧で scrollToTop が更新を走らせない(Android は a11y のスクロール操作で送る)")
    func S0010() {
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
}
