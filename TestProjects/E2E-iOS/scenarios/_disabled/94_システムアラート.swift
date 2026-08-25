// **陽性対照(意図的に失敗する)**。緑の run では観測できない側を確かめるための台なので、
// 通常実行に載せる `scenarios/` 直下には置かない。
//
// 守っているもの: OS の権限アラート(ATT・写真・位置情報)が画面を覆っている間、
// **背面のアプリへの操作を通さない**こと(2026-08-20 受け手報告)。
//
// なぜ起きるか(コードで確認済み):
//   - in-app のタップは `accessibilityActivate`(要素への**直接のメソッド呼び出し**)か
//     自プロセスの窓への合成タッチで、**OS のイベント経路を通らない**
//   - in-app の木は自プロセスしか見えないので、SpringBoard のアラートは載らない
//   - `systemAlertButtons` の自動クローズは「対象がどちらの木でも解決できないとき」だけ
//     呼ばれていたので、背面が解決できてしまうこの形では一度も発火しなかった
//   - **Android は影響を受けない**: 木の根が `getRootInActiveWindow()` なので、権限ダイアログが
//     出るとアプリの要素が木から丸ごと消え、既存の経路が正しく働く
//
// **使えなかった信号**(2026-08-21 実測。再提案する前に読むこと):
//   `UIApplication.applicationState`。アラート表示中でも `active` のままの端末があり、
//   同じ写真の権限アラートで **-01 は inactive・-02 は active**(0.3 秒刻み 42 サンプル)と
//   割れた。判定は XCUITest ランナーの `GET /systemalert` に一本化してある。
//
// **登録はシナリオ自身が行う**(`iosAlertHandler`)。
// ゲートは**登録が残っているときだけ働く**。登録の button(「Appの使用中は許可」)は
// 写真のアラートのボタン(写真を選択 / フルアクセスを許可 / 許可しない)と
// **わざと一致させていない** —— 一致すると自動で閉じてしまい、③(撃たずに待って落ちる)を
// 観測できない。alert は一致させてある = 「題名は合っているのにボタンが無い」形。
//
// 回し方:
//   cp _disabled/94_システムアラート.swift ../ && \
//   fleetest run --project E2E-iOS --profile ios-inapp --scenario システムアラートの陽性対照.S0010
//
// 期待する結果: **背面を撃つステップ以降で失敗**(操作側で止まるか、検証側で緑を取り消すかは
// 整定の間合いで変わる)。メッセージに "system UI is covering the app" が出て、
// **覆っているアラートの題名と、そのアラートに実際に在るボタン**が名指しされること
// (failureKind=system-ui-covered)。
// **緑になったらゲートが効いていない**(受け手報告 2026-08-20 の状態に戻っている)。

import FTDSL

@TestClass(app: "com.ftester.e2e.ios", platform: "ios")
class システムアラートの陽性対照 {

    @Test("覆われている間に背面を撃つと止まる(失敗するのが正解)")
    func S0010() {
        scenario {
            scene(1, "権限アラートを出したまま背面のボタンを撃つ") {
                condition {
                    // ボタンが一致しない予告 = ゲートは働くが自動では閉じられない(③の観測)
                    iosAlertHandler(alert: "*写真ライブラリ*", button: "Appの使用中は許可")
                    clearAppData()
                    launchApp()
                    tap("#nav_diagnostics", scroll: .down)
                }.action {
                    tap("#btn_request_photos")
                    wait(2)
                    // 人手では触れないボタン。**ここで止まる**
                    tap("#btn_freeze_3s")
                }.expectation {
                    exist("#txt_diag_note")
                }
            }
        }
    }
}
