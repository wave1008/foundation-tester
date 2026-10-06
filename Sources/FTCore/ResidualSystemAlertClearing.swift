// 各シナリオの開始前に画面に残っているシステムアラートを、**ボタンを押さずに**消す(ユーザー決定)。
// 判定と文言だけ(純粋)。実際の問い合わせ・SpringBoard の起こし直し・ブリッジの作り直しは
// FTAndroid の `ProfileWorkerFactory.clearResidualSystemAlert`。
//
// - なぜ要るか: 許可アラートは SpringBoard が描くので、アプリを terminate しても消えない
//   (`ResidualSystemAlertTriage`)。run の途中で1枚残ると、同じレーンの後続シナリオが全部
//   「a system alert is in front of the app」で落ち、レーンの復帰も使い切る(E2E で 16 回)
// - **押さない**: どのボタンが是認かは文脈で変わり、取り違えると意図しない権限状態のまま走る
//   (`SystemAlertDismissal`)。押してよいのは `iosAlertHandler` に登録された分だけ、のまま
// - **消し方は Simulator の SpringBoard の起こし直し**(実測: 約5秒でホームが戻る)。**XCUITest
//   ランナーの HTTP も一緒に死ぬ**ので、そのデバイスのブリッジを作り直す(実測 14 秒)。払うのは
//   残っていたときだけ。実機と、ブリッジを作り直せない経路(プロファイルの無い run)は警告だけ

import Foundation

public enum ResidualSystemAlertClearing {

    public enum Plan: Equatable, Sendable {
        /// 残っていない(または判定できない)
        case nothing
        /// 消せない構成なので警告だけ出す
        case warnOnly(String)
        /// SpringBoard を起こし直して消す
        case clear
    }

    /// `canRebuildBridge` = 起こし直しで死ぬ XCUITest ランナーを作り直せるか(プロファイルの run の Simulator)。
    /// 判定できない(probe が nil = 旧ランナーの 404・問い合わせの失敗)ときは何もしない
    public static func plan(probe: SystemAlertProbeResponse?, label: String, physical: Bool,
                            canRebuildBridge: Bool) -> Plan {
        guard let probe, probe.present else { return .nothing }
        let alert = describe(probe)
        if physical {
            return .warnOnly("⚠️ \(label): a system alert is still on screen before this scenario (\(alert))"
                + " — it cannot be dismissed without pressing a button on a physical device; dismiss it on the"
                + " device, or register iosAlertHandler for it in the scenario that raises it")
        }
        guard canRebuildBridge else {
            return .warnOnly("⚠️ \(label): a system alert is still on screen before this scenario (\(alert))"
                + " — not dismissed: restarting SpringBoard also stops the XCUITest bridge, and this run"
                + " (no run profile) cannot rebuild it; dismiss it on the simulator, or run with --profile")
        }
        return .clear
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

    public static func failedMessage(label: String, alert: String, reason: String) -> String {
        "⚠️ \(label): a system alert was left on screen before this scenario (\(alert)) and could not be"
            + " dismissed: \(reason)"
    }
}
