// ftester run --profile の実行パス:
//   実行プロファイル解決 → ワーカー構築(iOS ブリッジ供給 / Android 照合)→
//   自動インストール → RunOrchestrator で両OS同時並列実行。
// ワーカー構築の実体は ProfileWorkerFactory。

import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

enum ProfileRunner {

    /// ワーカー復帰待ちの上限。監視側の再起動やデバイス自己回復を待つ
    private static let REVIVE_TIMEOUT: TimeInterval = 90

    /// 戻り値: 実行サマリ(失敗数+劣化ワーカー)
    static func run(project: TestProject, profileName: String, items: [ScenarioRunItem],
                    healOverride: Bool?, reportDirOverride: String?,
                    recorder: RunRecorder? = nil) async throws -> RunSummary {
        let runClockStart = Date()
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

        // 1.5. Android AVD 肥大化チェック(超過分は Wipe Data。buildWorkers 前に実行)
        var wipedAndroid: [String] = []
        if resolved.wipeDataOnBloat {
            wipedAndroid = await AndroidDataWiper.wipeBloatedAVDs(
                devices: resolved.androidDevices, thresholdGB: resolved.wipeDataThresholdGB,
                locale: resolved.locale) { print($0) }
        }

        // 2. Android ワーカー構築(serial 照合=数秒)→ 白化デバイス除外 → 自動インストール。
        // iOS(ブリッジ供給=壊れたブリッジの置き換えで数十秒かかりうる)は lateWorkers として
        // 分離し、Android を供給完了待ちにしない(ApiRunCommand の並列経路と同じ方針)。
        let repoRoot = try RepoRoot.find()
        var workers = try ProfileWorkerFactory.buildAndroidWorkers(resolved: resolved)
        workers = try await excludeBlankScreenWorkers(workers)
        workers = try await ProfileWorkerFactory.installIfNeeded(
            apps: resolved.apps, workers: workers,
            forceAndroidInstall: !wipedAndroid.isEmpty) { print($0) }
        let hasLateIOS = !resolved.iosDevices.isEmpty

        // 3. 両OS同時並列実行(platform 別キューは RunOrchestrator がそのまま担う)
        let defaultPlatform = (hasLateIOS || workers.contains { $0.platform == "ios" })
            ? "ios" : "android"
        print("🚀 Android \(workers.count) ワーカーで開始"
            + (hasLateIOS ? "(iOS はブリッジ供給完了後に合流)" : "") + "\n")

        // run-lease(.ftester/run-<key>.lease)。best-effort: リポジトリ外実行等で root が
        // 取れない場合は書かない(monitor 側の inRun 判定が false になるだけで安全)
        let leaseStateDir = (try? RepoRoot.find())?.appendingPathComponent(".ftester")

        let orchestrator = RunOrchestrator(
            project: project, workers: workers, healingEnabled: heal,
            reportDir: reportDir, defaultTimeout: resolved.defaultTimeout,
            scenarioTimeout: resolved.scenarioTimeout, recorder: recorder,
            isDeviceFrozen: { serial in
                // 事後判定は isBlankObserved(窓内に一度でも blank)。isPersistentlyBlank だと
                // 約25秒周期のフラッピングの回復側を引いて凍結を見逃す(実測 2026-07-18)
                await AndroidHealthProbe.isBlankObserved(serial: serial)
            },
            isDeviceUnreachable: { serial in
                // adb で state=device の一覧に居なければ消失(offline/未検出)。取得失敗時は誤って
                // 振り直さないよう false(reachable 扱い)に倒す。
                guard let serials = try? AndroidDeviceCatalog.connectedSerials() else { return false }
                return !serials.contains(serial)
            },
            writeRunLease: { key in
                guard let leaseStateDir else { return }
                RunLease.write(stateDir: leaseStateDir, key: key, pid: ProcessInfo.processInfo.processIdentifier)
            },
            removeRunLease: { key in
                guard let leaseStateDir else { return }
                RunLease.remove(stateDir: leaseStateDir, key: key)
            },
            reviveWorker: { retired in
                guard let name = retired.logicalName else { return nil }
                let deadline = Date().addingTimeInterval(REVIVE_TIMEOUT)
                while Date() < deadline {
                    if let w = await ProfileWorkerFactory.buildWorker(forLogicalName: name, resolved: resolved,
                                                                       repoRoot: repoRoot, log: { print($0) }) {
                        let installed = (try? await ProfileWorkerFactory.installIfNeeded(
                            apps: resolved.apps, workers: [w], forceAndroidInstall: false) { print($0) }) ?? [w]
                        return installed.first ?? w
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                return nil
            },
            lateWorkers: hasLateIOS ? (platforms: Set(["ios"]), provider: { @Sendable in
                do {
                    var ws = try await ProfileWorkerFactory.buildIOSWorkers(
                        resolved: resolved, repoRoot: repoRoot) { print($0) }
                    ws = (try? await ProfileWorkerFactory.installIfNeeded(
                        apps: resolved.apps, workers: ws, forceAndroidInstall: false) { print($0) }) ?? ws
                    print("🚀 iOS \(ws.count) ワーカーが合流")
                    return ws
                } catch {
                    // iOS 供給失敗は run 全体を落とさない(iOS シナリオはワーカー不在ドレインで失敗確定)
                    print("❌ iOS ワーカー構築に失敗しました: \(error.localizedDescription)")
                    return []
                }
            }) : nil)
        async let summary = orchestrator.run(items: items, defaultPlatform: defaultPlatform)

        // シナリオ毎にバッファして完了時に一括表示(並列時のステップ行の混線防止)
        var buffers: [URL: [String]] = [:]
        var timing = ScenarioTimingTracker()
        for await event in orchestrator.events {
            timing.record(event)
            let lines = RunLogFormatter.lines(for: event)
            switch event {
            case .flowStarted(_, let url, _, _), .step(_, let url, _), .flowHealed(_, let url),
                 .flowRequeued(_, let url, _, _, _):
                buffers[url, default: []].append(contentsOf: lines)
            case .flowFinished(_, let url, _, _, _):
                let all = (buffers.removeValue(forKey: url) ?? []) + lines
                print(all.joined(separator: "\n"))
            default:
                if !lines.isEmpty { print(lines.joined(separator: "\n")) }
            }
        }

        let totalSeconds = Date().timeIntervalSince(runClockStart)
        let testStr = timing.testSeconds.map { String(format: "%.1f", $0) } ?? "-"
        let scenarioTotalStr = timing.scenarioTotalSeconds.map { String(format: "%.1f", $0) } ?? "-"
        print("⏱ トータル: \(String(format: "%.1f", totalSeconds))s / "
            + "テスト実時間: \(testStr)s / シナリオ合計: \(scenarioTotalStr)s")

        let finalSummary = await summary
        if !finalSummary.degradedWorkers.isEmpty {
            print("⚠️ 劣化・離脱したワーカー(\(finalSummary.degradedWorkers.count)):")
            for entry in finalSummary.degradedWorkers { print("   - \(entry)") }
        }
        if !finalSummary.freezeRetries.isEmpty {
            print("🔁 結果取り消し+振り直し(\(finalSummary.freezeRetries.count)):")
            for entry in finalSummary.freezeRetries { print("   - \(entry)") }
        }
        return finalSummary
    }

    /// android かつ serial 判明済みのワーカーを対象に恒常 blank-screen(画面凍結)を並列判定して
    /// 除外する。健全機は1サンプルで即返るため全機健全なら数秒で通過(白い機のみ最大 ~32s 待つ)。
    /// 元 workers の順序は維持する
    private static func excludeBlankScreenWorkers(_ workers: [RunWorker]) async throws -> [RunWorker] {
        let candidates = workers.enumerated().filter {
            $0.element.platform == "android" && $0.element.connection.serial != nil
        }
        guard !candidates.isEmpty else { return workers }

        let blankIndices = await withTaskGroup(of: Int?.self, returning: Set<Int>.self) { group in
            for (index, worker) in candidates {
                group.addTask {
                    guard let serial = worker.connection.serial else { return nil }
                    return await AndroidHealthProbe.isPersistentlyBlank(serial: serial) ? index : nil
                }
            }
            var result: Set<Int> = []
            for await index in group {
                if let index { result.insert(index) }
            }
            return result
        }
        guard !blankIndices.isEmpty else { return workers }

        for index in blankIndices.sorted() {
            print("⚠️ \(workers[index].label): 画面が白化(blank-screen)しているためディスパッチから除外します")
        }
        let filtered = workers.enumerated().filter { !blankIndices.contains($0.offset) }.map(\.element)
        guard !filtered.isEmpty else {
            throw ProfileWorkerFactory.InstallError(
                message: "実行可能なデバイスがありません(全 Android デバイスが白化)")
        }
        return filtered
    }
}
