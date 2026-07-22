// 91_クラッシュ検知.swift
// 破壊的(アプリを実際にクラッシュさせる)なので通常実行(Scenarios/ 直下)には載せず _disabled/ に置く。
// 人がクラッシュ検知を目視確認するための手動シナリオ。
//
// ftester 機能: 操作でアプリが落ちたときの検知とレポート添付。#btn_crash_confirm で
// プロセスを即異常終了させ、以降のコマンドが失敗としてレポートに記録されることを人が確認する。
// **Android のブリッジは別プロセス(instrumentation)なので切断しない**。iOS inapp のような
// .ips 添付は無く、「アプリが落ちた後の操作が解決不能で失敗する」形で現れる。
// SUT のクラッシュ手段: メインスレッドでの未捕捉 RuntimeException

import FTDSL

@TestClass(app: "com.ftester.e2e.android", platform: "android")
class クラッシュ検知でブリッジ切断とレポートが記録されること {

    @Test("クラッシュ後に操作失敗がレポートに記録される")
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
