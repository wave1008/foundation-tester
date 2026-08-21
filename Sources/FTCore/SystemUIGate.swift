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
//
// **働くのは `iosSystemAlertButtons` を宣言した実行だけ**(2026-08-21 ユーザー決定)。
// アラートが出る画面は書き手が知っているので宣言できるはずで、宣言しない実行に
// 毎ステップの往復を負わせない。呼び出し側(StepExecutor)が宣言の有無で門を閉じるので、
// この型自体は宣言を見ない(判定と方針を混ぜない)。

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
    /// **この機構は `iosSystemAlertButtons` を宣言したときだけ働く**ので、ここに来た時点で
    /// 宣言は必ずある。一致しなかったのだから、次の一手に要るのは
    /// **「宣言した名前」と「実際にそのアラートに在る名前」の両方**(2026-08-20 受け手依頼)。
    ///
    /// 実際の名前を出さなかった頃は、受け手が**シミュレータの画面を連続撮影して**
    /// 正解のラベルを探すしかなかった(数秒で消えるアラートもあり捕まらない)。
    /// ボタンは `GET /systemalert` が題名と同じ1往復で返しているので、出さない理由が無い。
    ///
    /// **読めなかったときは黙らずにそう言う** —— 「出していない」のか「読めなかった」のかで
    /// 受け手の次の一手が変わる
    public static func failureMessage(covering: String?, actualButtons: [String],
                                      declaredButtons: [String]) -> String {
        var message = "system UI is covering the app"
        if let covering { message += " (\(covering))" }
        message += ". The in-app engine could still reach the app, but a person could not,"
            + " so the step was not performed."
        message += " None of iosSystemAlertButtons"
            + " (\(declaredButtons.joined(separator: " / "))) matched a button on it."
        let actual = actualButtons.filter { !$0.isEmpty }
        if actual.isEmpty {
            message += " This alert reported no button labels, so there is nothing to match"
                + " — dismiss it in the scenario instead."
        } else {
            message += " Buttons on this alert: "
                + actual.map { "「\($0)」" }.joined(separator: " / ")
                + ". Add the one you want pressed to iosSystemAlertButtons,"
                + " or dismiss it in the scenario."
        }
        return message
    }
}
