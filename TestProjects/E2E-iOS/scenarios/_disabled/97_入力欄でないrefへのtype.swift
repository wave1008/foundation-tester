// 97_入力欄でないrefへのtype.swift
// **陽性対照**(既定スイートには載せない): 欄に焦点を残したまま**入力欄でない要素**へ type すると、
// 前の欄へ打たずに断ることを、**hybrid の DSL を端から端まで**通して確かめる。
// 回すのは Scripts/e2e-negative.sh(ios-inapp。期待値は Scripts/negative-controls.json)。
// **S0010 は落ちるのが正常**: ホストが type を**撃つ前に**断る(`nonTextInputPreflightRefusal`。文言
// 「the target is a button, not a text field — refusing before anything is typed」)。ボタンへ撃つと
// ドライバがまずタップするので押してしまう(送信・購入)。
// **type が緑になったら退行**(前の欄へ打っている)。**断る文言が撃ち直しの門(「not retried via XCUITest」)に
// 変わったら、撃つ前の門が抜けている**(in-app へ撃って 409 を受けてから断っている = もう押している)。
// 撃ち直しの門そのものはボタン型の容器(中に入力欄が1つ)でしか届かず、この画面には無いので単体テストが持つ。
import FTDSL

@TestClass(platform: "ios")
class 入力欄でないrefへのtype {

    @Test("欄に焦点を残してボタンへ type すると断る(落ちるのが正常)")
    func S0010() {
        scenario {
            scene(1, "欄に焦点を残す") {
                condition {
                    clearAppData()
                    launchApp()
                    tap("#nav_input")
                }.action {
                    tap("#field_single")
                }.expectation {
                    select("#txt_echo_single").textIs("single=")
                }
            }
            scene(2, "入力欄でないボタンへ type → 断られる") {
                action {
                    type("#btn_input_submit", "Q")
                }
            }
        }
    }
}
