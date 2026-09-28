// 23_絵の追いつき_inapp.swift
// **in-app エンジンだけの証人**(v117: 撮る前に絵の追いつきを待つ)。CMP iOS の in-app は、起動後の初回訪問で
// タップが返ってから 0.3〜0.45 秒のあいだ切り替え前の絵を返した。**待たずに撮る**のが要点なので waitSeconds を渡さない。
// XCUITest エンジンは同じ遅れを直していない(既知の制約)ので、このシナリオは赤になる。
// だから @Draft にして通常の実行から外し、**Scripts/e2e.sh が in-app のときだけ名指しで回す**
// (同期相手: Scripts/e2e.sh の run_inapp_witness)。

import FTDSL

@TestClass(platform: "ios")
class 絵の追いつきを待ってから撮る {

    @Draft("in-app エンジンの証人。Scripts/e2e.sh が in-app のときだけ名指しで回す(XCUITest は既知の制約で赤)")
    @Test("起動直後の初回訪問で、待たずに findImage で掴んで叩く")
    func S0010() {
        scenario {
            scene(1, "タブを切り替えてすぐ撮る") {
                condition {
                    launchApp()
                    tap("#tab_controls")
                }.action {
                    findImage("[Checkbox]").tap()
                }.expectation {
                    select("#txt_cb_agree").textIs("agree=true")
                }
            }
        }
    }
}
