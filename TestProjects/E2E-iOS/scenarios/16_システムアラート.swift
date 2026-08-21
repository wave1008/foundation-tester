// **OS の権限アラートはシナリオ自身で操作できる**ことの回帰。
//
// witness は E2EAppIOS の `#btn_request_photos`(写真ライブラリの権限)。SpringBoard が
// 別プロセスで出すアラートなので **in-app の木には載らず**、fallback(XCUITest の
// springboard 参照セッション)経由でだけ見える。ここが壊れると、権限アラートを自分で
// 操作するシナリオが1本も書けなくなる。
//
// **ATT ではなく写真**なのは、ATT が `simctl privacy` に該当サービスを持たず**一度答えると
// 再現できない**ため。写真は `clearAppData()`(内部で `simctl privacy reset all` を撃つ)で
// 何度でも再武装できるので回帰として回せる。覆いの性質は同じ。
//
// **この台は「覆われている間に背面を操作させない」ことは検証していない**(それは今日の
// ツールでは実現できていない。_disabled/94_システムアラート が現状を再現する陽性対照)。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class システムアラートの操作 {

    @Test("権限アラートは fallback 経由で見えて操作できる")
    func S0010() {
        scenario {
            scene(1, "写真の権限アラートを出す") {
                condition {
                    // 権限は**データコンテナの外**(デバイスの TCC.db)にあるので、
                    // これが無いと2回目以降の実行ではアラートが出ない
                    clearAppData()
                    launchApp()
                    tap("#nav_diagnostics", scroll: .down)
                    select("#txt_photos_result").textIs("photos=none")
                }.action {
                    tap("#btn_request_photos")
                }.expectation {
                    // in-app の木には載らない = fallback で解決できていること
                    exist("許可しない")
                }
            }
            scene(2, "閉じればアプリの操作に戻れる") {
                action {
                    tap("許可しない")
                }.expectation {
                    select("#txt_photos_result").textIs("photos=denied")
                    exist("#btn_freeze_3s")
                }
            }
        }
    }
}
