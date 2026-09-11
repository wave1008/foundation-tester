// 97_入力欄でないrefへのtype.swift
// **陽性対照**(既定スイートには載せない): 欄に焦点を残したまま**入力欄でない要素**へ type すると、
// 前の欄へ打たずに断ることを、**hybrid の DSL を端から端まで**通して確かめる。
// in-app ブリッジは 409 で断るが、hybrid のホストは 409 を XCUITest へ撃ち直すので、ブリッジ単体の
// 確認では「XCUITest 側が前の欄へ打って緑」を見落とす(実際に見落として素通りしていた)。
// 回し方: `fleetest run-file TestProjects/E2E-iOS/scenarios/_disabled/97_入力欄でないrefへのtype.swift
//   --project E2E-iOS --profile ios-inapp`(hybrid = XCUITest フォールバックがある構成)。
// **S0010 は落ちるのが正常**: type のステップが「keyboard focus did not move when the target was tapped」
// (XCUITest の 422)で失敗し、失敗時の画面の `#txt_echo_single` が `single=` のまま(Q が入っていない)。
// **type が緑になったら退行**(前の欄へ打っている)。
import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
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
