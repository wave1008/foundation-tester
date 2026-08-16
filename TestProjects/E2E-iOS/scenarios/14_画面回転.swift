// 14_画面回転.swift
// ftester 機能: `rotateTo(.portrait / .landscape)`。**契約は「アプリの UI がその向きになること」**
// で、デバイスがどう傾いているかではない(docs/commands.md)。左右の区別は語彙に無い。
// SUT は iOS ネイティブ(SwiftUI+UIKit)の E2EAppIOS。**iOS は接続が使っているエンジンで回す**
// (in-app = シーンの geometry / XCUITest = XCUIDevice)ので、この1本が両エンジンの回帰を兼ねる
// (--ios-inapp でも回すこと)。回した向きはシナリオ終了時に自動で戻る。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
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
