// 96_未登録のシステムアラート.swift
// **陽性対照**(既定スイートには載せない): `iosAlertHandler` の登録が無いまま OS のアラート
// (写真の権限)が前面に出ているとき、ツールが①次のフェーズの最初の触る操作で注記
// `system-alert-present` を残し ②失敗文言に題名とボタンを添えることを確かめる。
// 回し方: scenarios/ 直下へ一時的に出し `ftester run --project E2E-iOS --profile ios-fpc --scenario 未登録のシステムアラート`
// (hybrid = XCUITest フォールバックがある構成でだけ判定できる)。**S0010 は落ちるのが正常**
// (最後の exist が時間切れ。失敗理由に「a system alert (「…写真…」, buttons: …) is in front of the app
// and no iosAlertHandler is registered」が出る)。scene 2 の tap には注記が付く。
// 登録がある側の回帰は 16_システムアラート、登録はあるが一致しない側は _disabled/94。
import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class 未登録のシステムアラート {

    @Test("登録無しでアラート越しに操作すると注記が付き、時間切れの失敗には題名が出る(落ちるのが正常)")
    func S0010() {
        scenario {
            scene(1, "写真の権限アラートを出す(登録は無い)") {
                condition {
                    clearAppData()
                    launchApp()
                    tap("#nav_diagnostics", scroll: .down)
                }.action {
                    tap("#btn_request_photos")
                }
            }
            scene(2, "次のフェーズの最初の触る操作で前面を確かめる → 注記。時間切れには題名") {
                condition {
                    // OS のアラートは要求の直後に非同期で出る。確かめるのは**触る瞬間**なので、
                    // 要求と同じ瞬間に触ると出る前に見て「無い」になる(実測: 間を置かないと
                    // 注記が付かず、次の失敗時の1往復でだけ名指しされた)。実シナリオでは
                    // 要求と次のフェーズの間に待ちが入るのが普通
                    wait(1)
                }.action {
                    // アラートが前面にあるが登録が無い → 止めずに撃ち、system-alert-present を残す
                    tap("#btn_freeze_3s")
                }.expectation {
                    // 無いものを待って時間切れ → 失敗文言にアラートの題名とボタンが出る
                    exist("#this_id_does_not_exist", timeout: 3)
                }
            }
        }
    }
}
