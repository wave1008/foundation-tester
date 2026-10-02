// 91_クラッシュ検知.swift
// 破壊的(アプリを実際にクラッシュさせる)なので通常実行(scenarios/ 直下)には載せず _disabled/ に置く。
// 回すのは Scripts/e2e-negative.sh(期待値 = Scripts/negative-controls.json の appCrash。iOS は in-app で回す)。
//
// fleetest 機能: 操作でアプリが落ちたときの検知とレポート添付。#btn_crash_confirm で
// プロセスを即異常終了させ、以降のコマンドが失敗としてレポートに記録される。
// iOS は in-app で回す(.ips が appCrash に載る)。XCUITest エンジンは appCrash を記録しない
// (docs/results-json.md)ので「session's app is not in the foreground」(422)としか現れない。
// Android は crash バッファの FATAL EXCEPTION(スレッド mqt_v_native)が appCrash に載る。
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
                    exist("#txt_home_marker", waitSeconds: 3)
                }
            }
        }
    }
}
