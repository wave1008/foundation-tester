// 90_シナリオ全体の打ち切り.swift
// **陽性対照**(既定スイートには載せない): `@Test(scenarioTimeout:)` がプロファイルの scenarioTimeout(既定 600)より
// 優先して、出力を続けている(進んでいる)シナリオでも全体の上限で打ち切ることを確かめる。
// 回すのは Scripts/e2e-negative.sh(期待値は Scripts/negative-controls.json)。
// **S0010 は落ちるのが正常**: 15 秒で打ち切られ(timedOut)、打ち切りの行が値の出所「(@Test scenarioTimeout)」と
// 「last output from the scenario …s before」(1 秒ごとに出力しているので小さい)を持つ。
// **緑になったら退行**(@Test の値が watchdog に届いていない)。
import FTDSL

@TestClass(platform: "ios")
class シナリオ全体の打ち切り {

    @Test("出力を続けていても @Test の上限(15 秒)で打ち切られる(落ちるのが正常)", scenarioTimeout: 15)
    func S0010() {
        scenario {
            scene(1, "1 秒ずつ進み続ける") {
                action {
                    launchApp()
                    for _ in 0..<60 { wait(1) }
                }.expectation {
                    exist("#txt_home_marker")
                }
            }
        }
    }
}
