// ftester run --profile の実行パス:
//   実行プロファイル解決 → ワーカー構築(iOS ブリッジ供給 / Android 照合)→
//   自動インストール → RunOrchestrator で両OS同時並列実行。
// ワーカー構築の実体は ProfileWorkerFactory。

import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

enum ProfileRunner {

    /// 戻り値: 失敗シナリオ数
    static func run(project: TestProject, profileName: String, items: [ScenarioRunItem],
                    healOverride: Bool?, reportDirOverride: String?,
                    recorder: RunRecorder? = nil) async throws -> Int {
        // 1. マシン決定 → プロファイル合成(実行プロファイル自身の machine 指定があれば最優先)
        let machine = try ProfileResolver.determineMachine(
            project: project, registered: LocalConfig.currentMachineName(),
            runProfileName: profileName)
        if machine.auto {
            print("→ マシンプロファイル自動採用: \(machine.name)(machines/ が 1 つのため)")
        }
        let resolved = try ProfileResolver.resolve(
            project: project, runName: profileName, machineName: machine.name)
        for warning in resolved.warnings { print("⚠️ \(warning)") }

        let heal = healOverride ?? resolved.heal
        let reportDir = reportDirOverride.map { URL(fileURLWithPath: $0) } ?? resolved.reportDir
        let deviceList = resolved.devices
            .map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
        print("🧩 プロファイル \(profileName): \(resolved.appName) @ \(resolved.machineName)")
        print("   デバイス: \(deviceList)")

        // 2. ワーカー構築(iOS 供給+Android 照合)→ 自動インストール
        var workers = try await ProfileWorkerFactory.buildWorkers(
            resolved: resolved, repoRoot: try RepoRoot.find()) { print($0) }
        workers = try await ProfileWorkerFactory.installIfNeeded(
            apps: resolved.apps, workers: workers) { print($0) }

        // 3. 両OS同時並列実行(platform 別キューは RunOrchestrator がそのまま担う)
        let defaultPlatform = workers.contains { $0.platform == "ios" } ? "ios" : "android"
        print("🚀 実行: \(workers.count) ワーカー(\(workers.map(\.label).joined(separator: " / ")))\n")

        let orchestrator = RunOrchestrator(
            project: project, workers: workers, healingEnabled: heal,
            reportDir: reportDir, defaultTimeout: resolved.defaultTimeout,
            scenarioTimeout: resolved.scenarioTimeout, recorder: recorder)
        async let summary = orchestrator.run(items: items, defaultPlatform: defaultPlatform)

        // シナリオ毎にバッファして完了時に一括表示(並列時のステップ行の混線防止)
        var buffers: [URL: [String]] = [:]
        for await event in orchestrator.events {
            let lines = RunLogFormatter.lines(for: event)
            switch event {
            case .flowStarted(_, let url, _, _), .step(_, let url, _), .flowHealed(_, let url):
                buffers[url, default: []].append(contentsOf: lines)
            case .flowFinished(_, let url, _, _, _):
                let all = (buffers.removeValue(forKey: url) ?? []) + lines
                print(all.joined(separator: "\n"))
            default:
                if !lines.isEmpty { print(lines.joined(separator: "\n")) }
            }
        }
        return await summary.failed
    }
}
