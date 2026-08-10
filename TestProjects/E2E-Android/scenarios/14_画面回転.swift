// 14_画面回転.swift
// ftester 機能: `rotateTo(.portrait / .landscape)`。**契約は「アプリの UI がその向きになること」**
// で、デバイスがどう傾いているかではない(docs/commands.md)。左右の区別は語彙に無い。
// SUT は View/XML(一部 Compose)の E2EAppAndroid。**Android はホスト側の adb(`user_rotation`)で
// 回し、そのために自動回転を切る**(切らないと角度が保持されない = 実測)。切った設定は
// シナリオ終了時に向きごと元へ戻る —— **その後始末の回帰をここで守る**。

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class 横向きでも操作できること {

    @Test("横向きにしてもタップが正しい要素に当たる")
    func S0010() {
        scenario {
            scene(1, "横向きにしてからナビゲーションを操作する") {
                condition {
                    launchApp()
                    rotateTo(.landscape)
                }.action {
                    tap("#nav_input")
                }.expectation {
                    // 回転後の座標系でタップが着地していれば、この画面に居る。
                    // **画面タイトルでは判定しない** —— 横向きでは画面外へ出る SUT がある
                    // (SwiftUI で実測)。入力欄はどの向きでも見えている
                    exist("#field_single")
                }
            }
            scene(2, "縦へ戻しても同じ画面のまま操作を続けられる") {
                condition {
                    rotateTo(.portrait)
                }.expectation {
                    // **回転を跨いで画面が保たれる**。Android の View/XML SUT は Activity が
                    // 作り直されるので、構成変更専用の引き継ぎを入れて初めて成立する
                    // (E2EAppAndroid/docs/ui-contract.md)。他の3 SUT は元から保つ
                    exist("#field_single")
                }.action {
                    // 戻り先はタブで指す(`#btn_back` は画面によって在ったり無かったりする)
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker")
                }
            }
        }
    }
}
