// OS のシステム UI(SpringBoard の権限アラート等)がアプリに被さっている間、
// **背面のアプリを操作・検証させない**ための判定。判定は1箇所(この型)に置く。
//
// なぜ要るか(2026-08-20 受け手報告):
// in-app ブリッジのタップは `accessibilityActivate`(要素への直接のメソッド呼び出し)か
// 自プロセスの窓への合成タッチで、**OS のイベント経路を通らない**。だから SpringBoard が
// 出すアラート(ATT・写真・位置情報)が画面を覆っていても届いてしまう —— 人手では不可能な
// 操作が通り、しかも in-app の木は自プロセスしか見えないのでレポートに痕跡が残らない。
//
// **Android は影響を受けない**: 木の根が `getRootInActiveWindow()` なので、権限ダイアログが
// 出るとアプリの要素が木から丸ごと消え、既存の「どちらでも解決できない → 閉じる」経路が働く。
//
// **`UIApplication.applicationState` は使えない**(2026-08-21 実測。再提案しない)。
// 同じ写真の権限アラートで **-01 は inactive・-02 は active** と端末で割れた
// (0.3 秒刻み 42 サンプルで1つの例外もなく active)。**偽陰性**に倒れるので、
// 事前フィルタとしても使えない。判定は SpringBoard に直接聞くしかない。
//
// 聞く口は XCUITest ランナーの `GET /systemalert`(`SystemAlertProbeResponse`)。
// 木を全部撮ると約 185ms のところ、**アラート無しで約 73ms**(実測 2026-08-21)。

import Foundation

public enum SystemUIGate {

    /// 覆われているか。**申告が無い(nil)なら判定しない** —— XCUITest ランナーが居ない構成
    /// (engine=inapp 固定・Android・旧ランナー)で操作を止めてはいけない
    public static func isCovered(_ probe: SystemAlertProbeResponse?) -> Bool {
        probe?.present == true
    }

    /// 何が載っているかの名指し。題名 → ボタンの並び、の順に採る。
    /// **読めなければ nil**(「システム UI が載っている」以上のことを推測で書かない)
    public static func describeCovering(_ probe: SystemAlertProbeResponse?) -> String? {
        guard let probe, probe.present else { return nil }
        if let title = probe.title, !title.isEmpty { return title }
        let buttons = probe.buttons.filter { !$0.isEmpty }
        guard !buttons.isEmpty else { return nil }
        return "buttons: " + buttons.prefix(4).joined(separator: " / ")
    }

    /// 待ち切れなかったときの失敗の言い分。
    ///
    /// **逃げ道まで書く**: 受け手はここで初めてこの機構の存在を知るので、「何が起きたか」
    /// だけでは次の一手が分からない。宣言済みのラベルがあるのに閉じられなかった場合は
    /// **一致しなかったこと自体**が手掛かりなので、そう言う
    public static func failureMessage(covering: String?, declaredButtons: [String]) -> String {
        var message = "system UI is covering the app"
        if let covering { message += " (\(covering))" }
        message += ". The in-app engine could still reach the app, but a person could not,"
            + " so the step was not performed."
        if declaredButtons.isEmpty {
            message += " Add the button label to iosSystemAlertButtons in the run profile"
                + " to dismiss it automatically, or dismiss it in the scenario."
        } else {
            message += " None of iosSystemAlertButtons"
                + " (\(declaredButtons.joined(separator: " / "))) matched a button on it."
        }
        return message
    }
}
