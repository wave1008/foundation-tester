// 各シナリオの開始前に画面に残っているシステムアラートを消す(ユーザー決定)。消し方は3段:
//   1. 副作用の無いボタン(`harmlessButtons`・ボタン1つだけの「OK」)があれば押す(1秒未満・実機でも効く)
//   2. 権限のダイアログの拒否側(`permissionDenyButtons`)を押す。**そのアプリの権限が「拒否」になる**ので、
//      シナリオのログに残す(`clearAppData()` から始まるシナリオなら未決定へ戻るので影響しない)
//   3. どれも無ければ Simulator の SpringBoard を起こし直す(ボタンを押さない。約 20 秒)
// **是認側(「許可」「Allow」等)はどの段でも押さない**。ラベルは完全一致で照合する(「キャンセル」が
// 「キャンセルして削除」に当たらない)。判定と文言だけ(純粋)。実際の問い合わせ・押下・起こし直し・
// ブリッジの作り直しは FTAndroid の `ProfileWorkerFactory.clearResidualSystemAlert`。
//
// - なぜ要るか: 許可アラートは SpringBoard が描くので、アプリを terminate しても消えない
//   (`ResidualSystemAlertTriage`)。run の途中で1枚残ると、同じレーンの後続シナリオが全部
//   「a system alert is in front of the app」で落ち、レーンの復帰も使い切る(E2E で 16 回)
// - 押してよい一覧は**ここの2つと、ソフトウェアアップデートの保留だけ**(`iosAlertHandler` の推測しない規律 =
//   `SystemAlertDismissal` の例外は、前のシナリオの残り物を消すこの1点だけ)。アップデートの保留はユーザー決定
//   (テスト中にアップデートはしない = 常に「あとで」)。インストールの側はどの段でも押さない
// - **SpringBoard の起こし直し**(実測: 約5秒でホームが戻る)は **XCUITest ランナーの HTTP も一緒に殺す**ので、
//   そのデバイスのブリッジを作り直す(実測 14 秒)。実機と、ブリッジを作り直せない経路(プロファイルの
//   無い run)は、押せるボタンが無ければ警告だけ

import Foundation

public enum ResidualSystemAlertClearing {

    public enum Plan: Equatable, Sendable {
        /// 残っていない(または判定できない)
        case nothing
        /// 消せない構成なので警告だけ出す
        case warnOnly(String)
        /// このラベルのボタンを押して消す。`deniesPermission` = 権限を拒否にする押下(ログに残す)
        case press(button: String, deniesPermission: Bool)
        /// SpringBoard を起こし直して消す(ボタンを押さない)
        case clear
    }

    /// 押しても何も決めないボタン(完全一致)
    public static let harmlessButtons: Set<String> = ["キャンセル", "Cancel", "閉じる", "Close"]
    /// ボタンが1つだけのとき押してよい(通知だけのアラート)。**複数あるときは押さない**(是認の意味になりうる)
    public static let soleButtons: Set<String> = ["OK"]
    /// 権限のダイアログの拒否側(完全一致。iOS は ’ と ' の両方の綴りを使う)
    public static let permissionDenyButtons: Set<String> = ["許可しない", "Don’t Allow", "Don't Allow"]
    /// ソフトウェアアップデートのアラートの題名(完全一致)。「あとで」は他のアラートでは別の意味になりうるので、題名で絞る
    public static let softwareUpdateTitles: Set<String> = ["ソフトウェアアップデート", "Software Update"]
    /// その保留のボタン(完全一致。実測の並び: 今すぐインストール / あとで / 詳細)
    public static let softwareUpdateLaterButtons: Set<String> = ["あとで", "Later"]
    /// 「あとで」の後に続けて出る選択の、通知だけ先送りする側(完全一致)。**もう片方の「今夜インストール」は押さない**
    public static let softwareUpdateRemindButtons: Set<String> = ["あとで通知", "Remind Me Later"]
    /// 続けて出る選択を見分ける印(今夜インストールと並んでいるときだけ「あとで通知」を押す)
    public static let softwareUpdateInstallTonightButtons: Set<String> = ["今夜インストール", "Install Tonight"]

    /// `canRebuildBridge` = 起こし直しで死ぬ XCUITest ランナーを作り直せるか(プロファイルの run の Simulator)。
    /// 判定できない(probe が nil = 旧ランナーの 404・問い合わせの失敗)ときは何もしない
    public static func plan(probe: SystemAlertProbeResponse?, label: String, physical: Bool,
                            canRebuildBridge: Bool) -> Plan {
        guard let probe, probe.present else { return .nothing }
        // アップデートの保留を先に見る: 続けて出る選択に「キャンセル」が並ぶと、何も決めないボタンとしてそちらを押し、
        // 保留にならずにすぐまた出る。題名か「今夜インストール」との組でしか一致しないので、他のアラートには効かない
        if let deferral = softwareUpdateDeferral(probe) {
            return .press(button: deferral, deniesPermission: false)
        }
        if let harmless = probe.buttons.first(where: harmlessButtons.contains) {
            return .press(button: harmless, deniesPermission: false)
        }
        if probe.buttons.count == 1, let sole = probe.buttons.first, soleButtons.contains(sole) {
            return .press(button: sole, deniesPermission: false)
        }
        if let deny = probe.buttons.first(where: permissionDenyButtons.contains) {
            return .press(button: deny, deniesPermission: true)
        }
        let alert = describe(probe)
        if physical {
            return .warnOnly("⚠️ \(label): a system alert is still on screen before this scenario (\(alert))"
                + " — it has no button that is safe to press, and a physical device cannot be cleared"
                + " otherwise; dismiss it on the device, or register iosAlertHandler for it in the scenario"
                + " that raises it")
        }
        guard canRebuildBridge else {
            return .warnOnly("⚠️ \(label): a system alert is still on screen before this scenario (\(alert))"
                + " — not dismissed: restarting SpringBoard also stops the XCUITest bridge, and this run"
                + " (no run profile) cannot rebuild it; dismiss it on the simulator, or run with --profile")
        }
        return .clear
    }

    /// ソフトウェアアップデートを保留にするボタン(押すものが無ければ nil)。題名が一致するアラートの「あとで」か、
    /// 「今夜インストール」と並んで出る「あとで通知」(題名は問わない = 続けて出る選択に題名が無いことがある)
    public static func softwareUpdateDeferral(_ probe: SystemAlertProbeResponse) -> String? {
        if let title = probe.title, softwareUpdateTitles.contains(title),
           let later = probe.buttons.first(where: softwareUpdateLaterButtons.contains) {
            return later
        }
        if probe.buttons.contains(where: softwareUpdateInstallTonightButtons.contains),
           let remind = probe.buttons.first(where: softwareUpdateRemindButtons.contains) {
            return remind
        }
        return nil
    }

    /// 「あとで」の後に続けて出る選択の「あとで通知」の ref とラベル(SpringBoard の木から)。アラートでもアクションシートでもよい
    /// —— ブリッジの問い合わせ(`/systemalert`)はアラートしか見ないので、シートで出ると問い合わせでは見えない。
    /// 同じ入れ物の子孫に「今夜インストール」と並んでいるときだけ返す(無ければ nil)
    public static func softwareUpdateFollowUpRemind(in elements: [ElementInfo]) -> (ref: Int, label: String)? {
        for (index, container) in elements.enumerated() where container.type == "alert" || container.type == "sheet" {
            var remind: (ref: Int, label: String)?
            var installTonight = false
            for candidate in elements[(index + 1)...] {
                guard candidate.depth > container.depth else { break }
                guard candidate.type == "button", let label = candidate.label else { continue }
                if softwareUpdateRemindButtons.contains(label) { remind = (candidate.ref, label) }
                if softwareUpdateInstallTonightButtons.contains(label) { installTonight = true }
            }
            if installTonight, let remind { return remind }
        }
        return nil
    }

    /// アップデートを保留にした1行。続けて出た選択も押したならそれも言う(「あとで」を押した事実を消さない)
    public static func deferredUpdateMessage(label: String, alert: String, later: String, remind: String?) -> String {
        "🧹 \(label): a software update alert was left on screen before this scenario (\(alert)) — pressed"
            + " \u{201C}\(later)\u{201D} to defer it" + (remind.map { " and \u{201C}\($0)\u{201D} on the follow-up choice" } ?? "")
            + " (no update is installed during a test)"
    }

    public static func describe(_ probe: SystemAlertProbeResponse) -> String {
        // 題名はそのまま(iOS の題名はアプリ名を引用符で含むので、括ると二重になる)
        let title = probe.title.flatMap { $0.isEmpty ? nil : $0 } ?? "no title"
        return probe.buttons.isEmpty ? title : "\(title), buttons: \(probe.buttons.joined(separator: " / "))"
    }

    public static func clearedMessage(label: String, alert: String, seconds: Double) -> String {
        "🧹 \(label): a system alert was left on screen before this scenario (\(alert)) — restarted SpringBoard"
            + " to dismiss it without pressing any button and rebuilt the bridge (\(String(format: "%.1f", seconds))s)"
    }

    public static func pressedMessage(label: String, alert: String, button: String,
                                      deniesPermission: Bool) -> String {
        let base = "🧹 \(label): a system alert was left on screen before this scenario (\(alert)) — pressed"
            + " \u{201C}\(button)\u{201D} to dismiss it"
        return deniesPermission
            ? base + "; the app's permission for it is now denied (clearAppData() resets it to undecided)"
            : base
    }

    /// 押すボタンの要素(アラートの子孫の中でラベルが完全一致する button)。無ければ nil
    public static func buttonRef(label: String, in elements: [ElementInfo]) -> Int? {
        for (index, element) in elements.enumerated() where element.type == "alert" {
            for candidate in elements[(index + 1)...] {
                guard candidate.depth > element.depth else { break }
                if candidate.type == "button", candidate.label == label { return candidate.ref }
            }
        }
        return nil
    }

    public static func failedMessage(label: String, alert: String, reason: String) -> String {
        "⚠️ \(label): a system alert was left on screen before this scenario (\(alert)) and could not be"
            + " dismissed: \(reason)"
    }
}
