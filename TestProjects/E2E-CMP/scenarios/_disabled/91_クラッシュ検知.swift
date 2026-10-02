// 91_クラッシュ検知.swift
// 破壊的(アプリを実際にクラッシュさせる)なので通常実行(scenarios/ 直下)には載せず _disabled/ に置く。
// 回すのは Scripts/e2e-negative.sh(期待値 = Scripts/negative-controls.json の appCrash。iOS は in-app で回す)。
//
// fleetest 機能: inapp ブリッジ切断時のクラッシュレポート添付。#btn_crash_confirm でプロセスを
// 即異常終了させ、以降のコマンドが bridgeConnectionRefused としてレポートに .ips 情報付きで
// 記録される。

import FTDSL

@TestClass(app: "com.ftester.e2e")
class クラッシュ検知でブリッジ切断とレポートが記録されること {

    @Test("クラッシュ後にブリッジ切断がクラッシュレポート付きで報告される")
    func S0010() {
        scenario {
            scene(1, "診断画面を開く") {
                condition {
                    launchApp()
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
            scene(3, "本当にクラッシュ: プロセスが異常終了する(以降 bridgeConnectionRefused を人が確認)") {
                action {
                    tap("#btn_crash_confirm")
                }.expectation {
                    // ここで inapp ブリッジのプロセスごと落ちるため、この exist は
                    // DriverError.bridgeConnectionRefused として失敗し、レポートに
                    // クラッシュレポート(.ips)のパスと終了理由が添付されることを人が確認する
                    exist("#txt_home_marker", waitSeconds: 3)
                }
            }
        }
    }
}
