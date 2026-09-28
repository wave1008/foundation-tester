// 41_ピンチで拡大.swift
// 確かめる癖: ピンチ(2本指のジェスチャ・倍率は指の動きで決まるので範囲で確かめる)。

import FTDSL

@TestClass
class ピンチで拡大できること {

    @Test("拡大して元に戻す")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_zoom", scroll: .down)
                }.expectation {
                    select("#txt_zoom_scale").textIs("scale=1.0")
                }
            }
            scene(2, "拡大") {
                action {
                    pinchOut("#zoom_target", scale: 2.0)
                }.expectation {
                    // 2 倍を指示しても実際の倍率は部品の感度で変わる(Android の ScaleGestureDetector で 1.2)。拡大したことを見る
                    select("#txt_zoom_scale").textMatches("^scale=(1\\.[1-9]|[2-4]\\.[0-9])$")
                }
            }
            scene(3, "元に戻す") {
                action {
                    tap("#btn_zoom_reset")
                }.expectation {
                    select("#txt_zoom_scale").textIs("scale=1.0")
                }
            }
        }
    }
}
