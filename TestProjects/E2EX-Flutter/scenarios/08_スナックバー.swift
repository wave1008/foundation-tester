// 08_スナックバー.swift
// 確かめる癖: Snackbar(一時的に出て消える・中の部品に testTag を付けられない = ラベルで指す)。

import FTDSL

@TestClass
class スナックバーを操作できること {

    @Draft("調査中: Flutter の iOS でスナックバーが木に見つからない(FM が止まった Mac で観測)")
    @Test("アクションをラベルで押す")
    func S0010() {
        scenario {
            scene(1, "出す") {
                condition {
                    launchApp()
                    tap("#nav_snackbar", scroll: .down)
                }.action {
                    tap("#btn_show_snackbar")
                }.expectation {
                    exist("削除しました")
                }
            }
            scene(2, "元に戻す") {
                action {
                    tap("元に戻す")
                }.expectation {
                    select("#txt_snackbar_result").textIs("snackbar=undo")
                    notExist("削除しました")
                }
            }
        }
    }

    @Draft("調査中: Flutter の iOS でスナックバーが木に見つからない(FM が止まった Mac で観測)")
    @Test("短いスナックバーが自然に消えるのを待つ")
    func S0020() {
        scenario {
            scene(1, "出して消えるのを待つ") {
                condition {
                    launchApp()
                    tap("#nav_snackbar", scroll: .down)
                }.action {
                    tap("#btn_show_snackbar_short")
                    exist("保存しました")
                    waitForClose("保存しました", waitSeconds: 10)
                }.expectation {
                    select("#txt_snackbar_result").textIs("snackbar=short-dismissed")
                }
            }
        }
    }
}
