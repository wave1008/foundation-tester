// 91_クラッシュ検知.swift
// 破壊的(アプリを実際にクラッシュさせる)なので通常実行(Scenarios/ 直下)には載せず _disabled/ に置く。
// 人がクラッシュ検知を目視確認するための手動シナリオ。
//
// ftester 機能: 操作でアプリが落ちたときの検知とレポート添付。#btn_crash_confirm で
// プロセスを即異常終了させ、以降のコマンドが失敗としてレポートに記録されることを人が確認する。
// **Flutter は in-app エンジンでは要素が1つも見えない**(a11y ツリーが取れず、どのセレクタも
// 解決できない。2026-07-23 実測。原因未特定)。よって iOS は `ios-xcuitest` で回す。
// その場合ブリッジは別プロセスなので .ips 添付ではなく
// 「Application ... is not running」(XCUITest 500)としてクラッシュが現れる。
// Android もブリッジが別プロセスなので同様に「要素が見つかりません」で現れる。
// SUT のクラッシュ手段: dart:ffi の NULL 参照(SIGSEGV)。Dart の throw はフレームワークに捕捉されて
// プロセスが落ちないため、意図的に不正メモリアクセスで落としている

import FTDSL

@TestClass(app: "com.ftester.e2e.flutter")
class クラッシュ検知でブリッジ切断とレポートが記録されること {

    @Test("クラッシュ後に操作失敗がレポートに記録される")
    func S0010() {
        scenario {
            scene(1, "診断画面を開く") {
                condition {
                    launchApp()
                }.expectation {
                    // Flutter は起動直後の数百 ms ポインタ入力を取りこぼす(E2EAppFlutter/docs/ui-contract.md)。
                    // 着地を確認してから操作する。
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
