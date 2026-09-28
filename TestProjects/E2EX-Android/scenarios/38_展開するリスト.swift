// 38_展開するリスト.swift
// 確かめる癖: 開閉するリスト(閉じた子は木に無い・開くアニメーション中の子)。

import FTDSL

@TestClass
class 展開するリストを操作できること {

    @Test("グループを開いて子を押す")
    func S0010() {
        scenario {
            scene(1, "閉じている") {
                condition {
                    launchApp()
                    tap("#nav_expand", scroll: .down)
                }.expectation {
                    notExist("#item_veg_2")
                }
            }
            scene(2, "野菜を開いて2つ目") {
                action {
                    tap("#group_veg")
                    tap("#item_veg_2")
                }.expectation {
                    select("#txt_expand_result").textIs("expand=item_veg_2")
                    notExist("#item_fruit_1")
                }
            }
        }
    }
}
