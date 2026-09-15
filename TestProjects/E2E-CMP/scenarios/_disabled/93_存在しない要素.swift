// 93_存在しない要素.swift
// **意図的に失敗する**シナリオ。存在しない要素を叩き、自己修復が「代わりは無い」と答えて
// 別の要素へ置き換えないこと(HealNoReplacementTests / HealProposalRejectedFallbackHintTests の実測元)を
// デバイスで通す。通常実行(scenarios/ 直下)には載せない。実行は `Scripts/fm-verify.sh`。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class 存在しない要素を自己修復で置き換えないこと {

    @Test("実在しない id のタップは自己修復されずに失敗する(このテストは失敗が正常)")
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
