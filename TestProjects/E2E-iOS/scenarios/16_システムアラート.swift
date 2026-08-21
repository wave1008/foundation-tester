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

    /// `iosAlertHandler` の正常系: 予告した権限アラートが自動で押され、背面の操作が続行する。
    /// 陽性対照(登録があるのに押せず止まる側)は _disabled/94。
    /// **登録の消費も観測する**: 発火後の scene 2 は監視が解除された状態で普通に動く
    @Test("予告したアラートは自動で閉じられ、操作が続行する")
    func S0020() {
        scenario {
            scene(1, "予告してからアラートが出る操作をする") {
                condition {
                    iosAlertHandler(alert: "*写真ライブラリ*", button: "許可しない")
                    clearAppData()
                    launchApp()
                    tap("#nav_diagnostics", scroll: .down)
                }.action {
                    tap("#btn_request_photos")
                    // アラートが被さったまま背面を撃つ。登録が無ければ system-ui-covered で
                    // 止まる形(94 と同じ)だが、登録があるので自動で閉じてから通る
                    tap("#btn_freeze_3s")
                }.expectation {
                    select("#txt_photos_result").textIs("photos=denied")
                }
            }
            scene(2, "発火後(監視解除後)も普通に操作できる") {
                action {
                    tap("#btn_back")
                }.expectation {
                    exist("#nav_diagnostics")
                }
            }
        }
    }
}
