// 98_写真の権限アラートを閉じる.swift
// 陽性対照 94 / 96_未登録 が残す写真の権限アラートを閉じるだけの補助シナリオ(単独では何も検証しない)。
// 回すのは Scripts/e2e-negative.sh(表の resetPhotos を持つ対照の前後。閉じた後に simctl privacy reset で
// 権限を未決定へ戻すので、次に要求したときもアラートが出る)。
// **アラートは OS が持ち、ボタンで答えるまで消えない**(2026-10-02 実測: simctl terminate・privacy reset・
// privacy revoke・clearAppData・launchApp のどれでも残り、次の対照の最初のタップに持ち越された)。
// アラートが出ていなければ何もせずに通る(ハンドラは一致したときだけ押す)。
import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class 写真の権限アラートを閉じる {

    @Test("残った写真の権限アラートを「許可しない」で閉じる")
    func S0010() {
        scenario {
            scene(1, "アプリを前に出し、触る操作でハンドラを発火させる") {
                condition {
                    iosAlertHandler(alert: "*写真ライブラリ*", button: "許可しない")
                    launchApp()
                }.action {
                    tap("#nav_diagnostics", scroll: .down)
                }.expectation {
                    exist("#txt_diag_note")
                }
            }
        }
    }
}
