// 14_画面回転.swift
// fleetest 機能: `rotateTo(.portrait / .landscape)`。**契約は「アプリの UI がその向きになること」**
// で、デバイスがどう傾いているかではない(docs/commands.md)。左右の区別は語彙に無い。
// SUT は Flutter の E2EAppFlutter。**自前描画のフレームワークでも再レイアウトされ、a11y ツリーが
// 新座標系で追随することの回帰**をここで守る(Compose と並ぶ2つ目の自前描画。観測側はホスト
// 無改修で追随する = 実測)。回した向きはシナリオ終了時に自動で戻る。
// platform 未指定 = ios/android 両方で回す。

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
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
