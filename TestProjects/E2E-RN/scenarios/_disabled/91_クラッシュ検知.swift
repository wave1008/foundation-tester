// 91_クラッシュ検知.swift
// 破壊的(アプリを実際にクラッシュさせる)なので通常実行(scenarios/ 直下)には載せず _disabled/ に置く。
// 人がクラッシュ検知を目視確認するための手動シナリオ。
//
// fleetest 機能: 操作でアプリが落ちたときの検知とレポート添付。#btn_crash_confirm で
// プロセスを即異常終了させ、以降のコマンドが失敗としてレポートに記録されることを人が確認する。
// **予測・未検証**: Flutter は in-app エンジンでは要素が1つも見えなくなる不具合が実測されている
// (a11y ツリーが取れず原因未特定)。RN の in-app ブリッジで同じ不具合が起きるかは未検証だが、
// 安全側として同じ運用(iOS は `ios-xcuitest` で回す)を踏襲する。その場合ブリッジは別プロセスなので
// .ips 添付ではなく「Application ... is not running」(XCUITest 500)としてクラッシュが現れるはず。
// Android もブリッジが別プロセスなので同様に「要素が見つかりません」で現れるはず。
// SUT のクラッシュ手段: `setTimeout` でイベントループの外に出してから投げる未捕捉例外
// (E2EAppRN/src/screens/DiagnosticsScreen.tsx crash())。release ビルドは try/catch に
// 握りつぶされない未捕捉例外でプロセスが終了する。

import FTDSL

@TestClass(app: "com.ftester.e2e.rn")
class クラッシュ検知でブリッジ切断とレポートが記録されること {

    @Test("クラッシュ後に操作失敗がレポートに記録される")
    func S0010() {
        scenario {
            scene(1, "診断画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // 起動直後は a11y ツリー完成後もポインタ入力を一時的に取りこぼす実装が
                    // Flutter で実測されている(E2EAppCMP/docs/ui-contract.md)。RN で同じ罠が
                    // あるかは未検証だが、着地を確認してから操作する。
                    exist("#txt_home_marker")
                }.action {
                    tap("#nav_diagnostics")
                }.expectation {
                    exist("#txt_diag_note")
                }
            }
            scene(2, "確認ダイアログを開く") {
                action {
                    tap("#btn_crash")
                }.expectation {
                    exist("#btn_crash_confirm")
                }
            }
            scene(3, "本当にクラッシュ: プロセスが異常終了する(以降の失敗を人が確認)") {
                action {
                    tap("#btn_crash_confirm")
                }.expectation {
                    // ここでアプリのプロセスが落ちるため、この exist は失敗する。
                    // 失敗の種類と添付情報を人が確認するのがこのシナリオの目的。
                    exist("#txt_home_marker", timeout: 3)
                }
            }
        }
    }
}
