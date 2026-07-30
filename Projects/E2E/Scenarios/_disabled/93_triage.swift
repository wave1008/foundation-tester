// 93_triage.swift
// **意図的に失敗する**シナリオ。失敗時 triage(FM による失敗分類)を発火させるためだけに存在する。
// 通常実行(Scenarios/ 直下)には載せない。実行は `Scripts/fm-verify.sh`。
//
// triage は失敗しないと呼ばれないので、全緑の E2E では 1 度も通らない。
// 実害(2026-07-30): triage が FMHealth に計上されておらず、fm フィールドに出ないまま気付かなかった。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class triage経路を検証できること {

    @Test("実在しない id の失敗が triage で分類される(このテストは失敗が正常)")
    func S0010() {
        scenario {
            scene(1, "実在しない id をタップして失敗させる") {
                condition {
                    launchApp()
                }.action {
                    tap("#btn_triage_check_does_not_exist")
                }
            }
        }
    }
}
