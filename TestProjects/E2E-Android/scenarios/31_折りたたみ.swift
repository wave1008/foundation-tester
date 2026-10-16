// 31_折りたたみ.swift
// fleetest 機能: `fold()` / `unfold()` / `hinge(_:)`(折りたたみの Android Emulator)。
// 開閉は画面が丸ごと替わる(Pixel 9 Pro Fold の AVD: 外側 1080x2424px ⇄ 内側 2076x2152px)ので、替わった後の座標でタップが着地するかを見る。
// **折りたたみ機でないデバイスではシナリオごと対象外(skipped)**になる(赤にならない)。
// 開閉はシナリオの終わりに自動で元へ戻る。回すのは profiles/runs/android-fold.json(Pixel 9 Pro Fold の AVD)

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class 折りたたみの開閉を跨いで操作できること {

    @Test("開いた画面と閉じた画面の両方でタップが正しい要素に当たる")
    func S0010() {
        scenario {
            scene(1, "開いてからナビゲーションを操作する") {
                condition {
                    launchApp()
                    unfold()
                }.action {
                    tap("#nav_input")
                }.expectation {
                    exist("#field_single")
                }
            }
            scene(2, "閉じても同じ画面のまま操作を続けられる") {
                condition {
                    fold()
                }.expectation {
                    exist("#field_single")
                }.action {
                    tap("#tab_home")
                }.expectation {
                    exist("#txt_home_marker")
                }
            }
        }
    }

    @Test("半開きの角度を送っても操作を続けられる")
    func S0020() {
        scenario {
            scene(1, "閉じた状態から半開きの角度を送る") {
                condition {
                    launchApp()
                    // Android の Emulator は角度の範囲で姿勢が決まる(30〜150° = 半開き = 内側の画面)
                    hinge(130)
                }.action {
                    tap("#nav_input")
                }.expectation {
                    exist("#field_single")
                }
            }
        }
    }
}
