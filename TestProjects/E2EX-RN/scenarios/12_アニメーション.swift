// 12_アニメーション.swift
// 確かめる癖: AnimatedVisibility(1.5 秒のフェード中は木に居るが薄い)・AnimatedContent(切り替え中は
// 新旧の2つが同時に木に居る)。

import FTDSL

@TestClass
class アニメーション中の要素を扱えること {

    @Test("フェードインした要素の文字を読む・消えるのを待つ")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_anim", scroll: .down)
                }.expectation {
                    select("#txt_anim_visible").textIs("visible=false")
                    notExist("#txt_anim_target")
                }
            }
            scene(2, "出す") {
                action {
                    tap("#btn_toggle_anim")
                }.expectation {
                    select("#txt_anim_target").textIs("アニメ完了")
                }
            }
            scene(3, "消す") {
                action {
                    tap("#btn_toggle_anim")
                    waitForClose("#txt_anim_target", waitSeconds: 5)
                }.expectation {
                    select("#txt_anim_visible").textIs("visible=false")
                }
            }
        }
    }

    @Test("AnimatedContent の切り替えを連打して最後の値を読む")
    func S0020() {
        scenario {
            scene(1, "3回増やす") {
                condition {
                    launchApp()
                    tap("#nav_anim", scroll: .down)
                }.action {
                    tap("#btn_anim_inc")
                    tap("#btn_anim_inc")
                    tap("#btn_anim_inc")
                }.expectation {
                    select("#txt_anim_count").textIs("count=3")
                }
            }
        }
    }
}
