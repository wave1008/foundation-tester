// 42_固有部品.swift
// 確かめる癖(Flutter 固有): Hero での遷移 / Cupertino 部品(CupertinoSwitch)/ PlatformView(ネイティブのラベルの埋め込み)。
// 契約は E2EXAppFlutter/docs/ui-contract.md §第2弾の実装(Flutter)

import FTDSL

@TestClass
class Flutterの固有部品を操作できること {

    @Test("Hero・CupertinoSwitch・PlatformView")
    func S0010() {
        scenario {
            scene(1, "Hero で開いて戻る") {
                condition {
                    launchApp()
                    tap("#nav_native", scroll: .down)
                }.action {
                    tap("#btn_hero")
                    tap("#btn_hero_back")
                }.expectation {
                    select("#txt_native_result").textStartsWith("native=hero:")
                }
            }
            scene(2, "CupertinoSwitch") {
                action {
                    tap("#sw_cupertino")
                }.expectation {
                    select("#txt_native_result").textStartsWith("native=cupertino_switch:")
                }
            }
            scene(3, "PlatformView のネイティブのラベルが木に載る") {
                action {
                    scrollTo("#native_label")
                    tap("#btn_platform_view_seen", scroll: .down)
                }.expectation {
                    exist("ネイティブのラベル", scroll: .down)
                    select("#txt_native_result", scroll: .up).textIs("native=platform_view:shown")
                }
            }
        }
    }
}
