// Simulator 上の対象アプリの生死(`simctl spawn <udid> launchctl list`)と、落ちた直後の .ips の待ち。
// in-app ドライバの切断の注記(InAppDriver.crashAnnotated)と、モードを問わない失敗時のプロセス証拠
// (ScenarioRunnerMain の appProcessEvidence。XCUITest モードではアプリが落ちても XCTest の
// 「Lost connection to the application」しか出ず、クラッシュの事実が記録に残らなかった)が共有する。
// 子のサンドボックスでは simctl は親の SandboxBroker が代行する(`spawn … launchctl list` は許可表にある)

import Foundation
import FTCore

public enum SimulatorAppProcess {
    /// `launchctl list` の直読み(5 秒 = SafariWebInspector の lsof 診断と同じ、応答が無ければ
    /// 待つ意味の無い読み取り専用診断の目安)
    static let launchctlListTimeoutSeconds: Double = 5

    /// .ips は落ちてから遅れて書かれる(実測: ブリッジ切断の約 2 秒後。E2E-iOS の 91_クラッシュ検知)ので、
    /// この間隔・回数で探す(500ms × 8 = 4 秒)
    static let crashReportPollMilliseconds: UInt32 = 500
    static let crashReportPollAttempts = 8

    /// 生きていれば true・居なければ false・simctl が答えなければ nil(判定できない = 生きていない、にはしない)。
    /// **同期で最大 5 秒ブロックする**(協調スレッドプールから呼ぶなら Task.detached で包む)
    public static func isRunning(udid: String, bundleID: String) -> Bool? {
        guard let result = try? Shell.run(["xcrun", "simctl", "spawn", udid, "launchctl", "list"],
                                          timeout: launchctlListTimeoutSeconds),
              result.status == 0 else { return nil }
        return processIsRunning(inLaunchctlListOutput: result.output, bundleID: bundleID)
    }

    /// `launchctl list` の1行は "PID\tステータス\tラベル"。対象アプリのラベルは
    /// "UIKitApplication:<bundleID>[" を含み、未起動なら PID 列が "-"。純粋関数でテストする
    static func processIsRunning(inLaunchctlListOutput output: String, bundleID: String) -> Bool {
        let marker = "UIKitApplication:\(bundleID)["
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard let label = fields.last, label.contains(marker) else { continue }
            guard let pidField = fields.first, Int(pidField) != nil else { continue }
            return true
        }
        return false
    }

    /// 直近 `within` 秒の .ips を、書かれるのを待ちながら探す(見つからなければ nil)。
    /// **同期で最大 4 秒ブロックする**。失敗が確定した経路だけから呼ぶ(正常系を遅らせない)
    public static func awaitCrashReport(bundleID: String, udid: String,
                                        within seconds: TimeInterval) -> (path: String, reason: String?)? {
        for attempt in 0..<crashReportPollAttempts {
            if let hit = SimulatorCrashReport.findRecent(bundleID: bundleID, udid: udid, within: seconds) {
                return hit
            }
            if attempt < crashReportPollAttempts - 1 { usleep(crashReportPollMilliseconds * 1000) }
        }
        return nil
    }

    /// 失敗時のプロセス証拠(`FTRuntime.appProcessEvidence` の iOS Simulator 版)。生きている・判定できないなら空。
    /// 居なければ "process not running" と、このシナリオの開始以降の .ips があればその事実を返し、
    /// クラッシュとして記録する(`LastAppCrash`。in-app ドライバが切断の時点で記録済みなら重ねない)
    public static func failureEvidence(bundleID: String, udid: String, scenarioStartedAt: Date) -> [String] {
        guard isRunning(udid: udid, bundleID: bundleID) == false else { return [] }
        if let recorded = LastAppCrash.shared.snapshot() {
            return ["process not running"] + (recorded.path.map { [crashReportLine(path: $0, reason: recorded.summary)] } ?? [])
        }
        // 前のシナリオ・前の run の同じアプリの .ips を拾わないよう、このシナリオの開始以降に絞る
        let within = Date().timeIntervalSince(scenarioStartedAt)
        guard let hit = awaitCrashReport(bundleID: bundleID, udid: udid, within: within) else {
            return ["process not running"]
        }
        LastAppCrash.shared.record(AppCrashRecord(evidence: .crashReport, path: hit.path, summary: hit.reason))
        return ["process not running", crashReportLine(path: hit.path, reason: hit.reason)]
    }

    /// 記録済み(in-app ドライバが切断の時点で見つけた)でも、ここで見つけても同じ形で言う
    static func crashReportLine(path: String, reason: String?) -> String {
        "crash report: \(path)" + (reason.map { " (\($0))" } ?? "")
    }
}
