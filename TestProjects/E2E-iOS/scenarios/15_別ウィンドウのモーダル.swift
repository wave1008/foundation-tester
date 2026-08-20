// **別 UIWindow に載るモーダル**(アプリ内メッセージ SDK 相当)が木に載ることの回帰。
//
// 受け手報告(2026-08-20): この形のモーダルが画面を覆っている間、iOS の回帰9本が
// **すべて緑のまま通った**。in-app の木はキーウィンドウ1枚しか歩かず、タップは activate、
// スクロールは contentOffset の直接書き込みで hitTest を経由しないので、
// **上に乗ったモーダルが障害物にならない**(= 偽陽性で緑になる)。
// irregularHandler も、木に載らないものは照合できないので発動しない。
//
// witness は E2EAppIOS の OverlayWindow(**キーウィンドウにしない**別 UIWindow)。
// `UIAlertController` は自分の窓を key にするので今日でも載る —— 載らない側がこの形。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class 別ウィンドウのモーダルが木に載ること {

    @Test("別ウィンドウのモーダルは木に載り、閉じられる")
    func S0010() {
        scenario {
            scene(1, "1.5 秒後に湧いたモーダルが木に載る") {
                condition {
                    launchApp()
                    tap("#nav_dialog")
                }.action {
                    tap("#btn_show_overlay")
                    wait(2.5)
                }.expectation {
                    // ここが落ちるなら「画面を覆っているのに木から見えない」状態
                    existWithoutScroll("#txt_overlay_title")
                    existWithoutScroll("#btn_overlay_close")
                }
            }
            scene(2, "モーダルは操作できて、閉じると消える") {
                action {
                    tap("#btn_overlay_close")
                }.expectation {
                    notExist("#btn_overlay_close", timeout: 3)
                    select("#txt_overlay_result").textIs("overlay=closed")
                }
            }
        }
    }

    @Test("上部バナーは背面を隠さない")
    func S0030() {
        scenario {
            scene(1, "バナーも背面も木に居る") {
                condition {
                    launchApp()
                    tap("#nav_dialog")
                    exist("#btn_show_dialog")
                }.action {
                    tap("#btn_show_banner")
                    wait(2.5)
                }.expectation {
                    // バナーが見える(別ウィンドウが載っている)
                    existWithoutScroll("#btn_banner_close")
                    // **背面も見える**(バナーは覆っていない = 触れる)。
                    // 「手前の窓だけ見せる」実装だとここが落ちる
                    existWithoutScroll("#btn_show_dialog")
                }
            }
        }
    }

    @Test("別ウィンドウのモーダルは irregularHandler が自動で閉じる")
    func S0020() {
        scenario {
            scene(1, "湧いたモーダルを待機中に閉じて、下の画面の操作を続ける") {
                condition {
                    // **この @Test だけに効かせる**(setUp に置くと S0010 のモーダルも
                    // 湧いた瞬間に閉じられ、「木に載る」の検証ができなくなる)。
                    // **木に載らなければ照合できないので発動しない** —— この宣言が効くこと自体が、
                    // 別ウィンドウが木に載っていることの裏返しになる
                    irregularHandler("アプリ内メッセージ", dismiss: "#btn_overlay_close")
                    launchApp()
                    tap("#nav_dialog")
                    tap("#btn_show_overlay")
                }.action {
                    // モーダルが湧く前に始まり、湧いた時点でハンドラが閉じる。
                    // 閉じられないと `overlay=closed` に届かない(下の画面は覆われたまま)
                    exist("#txt_overlay_result", timeout: 10)
                }.expectation {
                    select("#txt_overlay_result").textIs("overlay=closed")
                    notExist("#btn_overlay_close", timeout: 3)
                }
            }
        }
    }
}
