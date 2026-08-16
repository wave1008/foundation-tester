// DeviceHostRunner.swift
// **1つの実行プロファイルのデバイスが複数の機械にまたがるとき**の実行(docs/remote-runner.md §13)。
// マシンプロファイルのデバイスは1台ずつ host を持てるので、「ローカル10台 + M1Ultra 10台」のような
// 混在が書ける。run はホストごとのサブ実行(この ftester 自身の子プロセス)へ分け、シナリオを
// 台数で重み付けして配り、出力・JUnit・終了コードを1つに束ねる。
//
// **フリート(--fleet)との違い**: あちらは「エントリごとに別の実行プロファイル」、こちらは
// 「同じ実行プロファイルをホストごとに担当デバイスだけで」。子プロセスの起動・行の前置・
// JUnit 結合・集計は FleetRunner の同じヘルパを共有する(prefix や中継の実装を二重に持たない)。
//
// 子には `--device <名前…>` と `--host <ホスト|local>` を渡す。--host を必ず渡すのは、
// 子が自分でマシンプロファイルの host を読んで再ディスパッチするのを止めるため(FleetRunner と同じ)。

import ArgumentParser
import FTCore
import Foundation

enum DeviceHostRunner {

    struct Group: Equatable {
        let host: String?
        let deviceNames: [String]
        let platforms: Set<String>

        /// 子プロセスへ渡すホスト表記(ローカルは "local")
        var hostLabel: String { DeviceHostGrouping.display(host) }
    }

    /// デバイスが2つ以上の機械にまたがっていれば、その分け方を返す。1つ(= 従来どおり全台が
    /// 同じ機械)なら nil を返し、呼び出し側は既存の単一ディスパッチ経路をそのまま通す。
    ///
    /// **`--host` を明示したときは常に nil** —— 明示指定は「今回はこの機械で走らせる」の意味で、
    /// 分散より強い(MachineHostDispatch と同じ「明示が勝つ」規律)。
    static func plan(project: TestProject, profileName: String,
                     explicitHost: String?, deviceFilter: [String]) throws -> [Group]? {
        if explicitHost != nil { return nil }
        let machine = try ProfileResolver.determineMachine(
            project: project, registered: LocalConfig.currentMachineName(),
            runProfileName: profileName)
        var devices = try ProfileResolver.runDeviceHosts(
            project: project, runProfileName: profileName, machineName: machine.name)
        if !deviceFilter.isEmpty {
            let wanted = Set(deviceFilter)
            devices = devices.filter { wanted.contains($0.name) }
        }
        let grouped = DeviceHostGrouping.groups(devices) { $0.host }
        guard grouped.count > 1 else { return nil }
        return grouped.map { group in
            Group(host: group.host,
                  deviceNames: group.devices.map(\.name),
                  platforms: Set(group.devices.map(\.platform)))
        }
    }

    /// ホストごとのサブ実行を並行に走らせ、1画面の集計を出す。戻り値 = 各サブ実行の非0の最大
    static func run(
        project: TestProject, profileName: String, groups: [Group],
        scenarios: [String], folders: [String],
        heal: Bool, noHeal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
        fastInput: Bool, enableAnimations: Bool, performanceMode: Bool,
        forceLock: Bool, remoteDir: String?, remoteTimeout: Int?, remoteArtifacts: String,
        quiet: Bool, junit: String?
    ) async throws -> Int32 {
        let junitTempDir = try FleetRunner.makeJUnitTempDir(requested: junit)
        defer { if let junitTempDir { try? FileManager.default.removeItem(at: junitTempDir) } }

        let hostList = groups.map { "\($0.hostLabel)(\($0.deviceNames.count))" }
            .joined(separator: " + ")
        FleetRunner.log("==> profile \"\(profileName)\" spans \(groups.count) machines:"
            + " \(hostList) — building \(project.name) locally to split the scenarios")

        // 割り当てを決めるにはシナリオ一覧が要る(--split と同じ理由でローカルで1回ビルドする)
        try ScenarioHost.build(project: project, log: { FleetRunner.log($0) })
        let all = try ScenarioHost.list(project: project)
        guard !all.isEmpty else {
            throw ValidationError(
                "no scenarios (add a @TestClass under TestProjects/\(project.name)/scenarios/)")
        }
        var selected = try RunScenarios.resolve(scenarios, from: all)
        if !folders.isEmpty {
            selected = try RunScenarios.filterByFolders(selected, folders: folders,
                                                        scenariosDir: project.scenariosDir)
        }
        guard !selected.isEmpty else {
            throw ValidationError("no scenarios to run after filtering")
        }

        let buckets = try assign(project: project, groups: groups, selected: selected,
                                 lptHistoryRuns: lptHistoryRuns)
        let active = groups.indices.compactMap { index -> (Int, Group, [String])? in
            let ids = buckets[index].scenarioIDs
            return ids.isEmpty ? nil : (index, groups[index], ids)
        }
        guard !active.isEmpty else {
            FleetRunner.log("==> no machine was assigned a scenario; nothing to run")
            return 0
        }
        for (index, group, ids) in active {
            FleetRunner.log("    \(group.hostLabel): \(ids.count) scenario(s)"
                + " on \(group.deviceNames.count) device(s)"
                + " [\(buckets[index].estimatedMs > 0 ? estimateText(buckets[index].estimatedMs, devices: group.deviceNames.count) : "no history")]")
        }

        let binary = FleetRunner.selfBinaryPath()
        let outcomes = await withTaskGroup(of: (Int, FleetEntryOutcome).self) { taskGroup in
            for (index, group, ids) in active {
                taskGroup.addTask {
                    let args = FleetRunner.buildArgs(
                        project: project.name, host: group.hostLabel, profile: profileName,
                        deviceNames: group.deviceNames, scenarios: ids, folders: [],
                        heal: heal, noHeal: noHeal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
                        fastInput: fastInput, enableAnimations: enableAnimations,
                        performanceMode: performanceMode, forceLock: forceLock,
                        remoteDir: remoteDir, remoteTimeout: remoteTimeout,
                        remoteArtifacts: remoteArtifacts, quiet: quiet,
                        junitPath: FleetRunner.entryJUnitPath(tempDir: junitTempDir, index: index))
                    let start = Date()
                    let exitCode = await FleetRunner.runEntry(
                        binary: binary, args: args, hostLabel: group.hostLabel)
                    return (index, FleetEntryOutcome(
                        host: group.hostLabel, profile: profileName, exitCode: exitCode,
                        duration: Date().timeIntervalSince(start)))
                }
            }
            var collected: [Int: FleetEntryOutcome] = [:]
            for await (index, outcome) in taskGroup { collected[index] = outcome }
            return active.compactMap { collected[$0.0] }
        }

        printSummary(profileName: profileName, outcomes: outcomes)
        // ディスパッチした(= --junit を渡した)ぶんだけ結合する。0本で見送ったホストを混ぜると
        // 「出力が無い」合成失敗になり、走らせてもいないものが赤くなる(FleetRunner と同じ規律)
        if let junit, let junitTempDir {
            FleetRunner.mergeAndWriteJUnit(
                junit: junit, project: project.name, tempDir: junitTempDir,
                entries: active.map { (host: $0.1.hostLabel, index: $0.0) })
        }
        return FleetProfile.aggregateExitCode(outcomes.map(\.exitCode))
    }

    // MARK: - 割り当て

    /// 実績(results)からの見積りで LPT 分割する。**重みは台数**(同時に回せる本数)——
    /// 総量で均すと台数の少ないホストが最後まで残る。実績が1件も無ければ全員同じ重みになり、
    /// 台数比での本数割りに退化する(FleetRunner.unknownDurationUnitWeight と同じ考え方)
    private static func assign(project: TestProject, groups: [Group],
                               selected: [ScenarioInfo], lptHistoryRuns: Int?)
        throws -> [FleetSplit.Bucket] {
        let historyRuns = max(1, lptHistoryRuns ?? LPTOrdering.defaultHistoryRuns)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        let since = Date().addingTimeInterval(-30 * 24 * 60 * 60)  // LPTOrdering.historyDays と同じ窓
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: since,
                                                  maxObservationsPerScenario: historyRuns)
        let durations = LPTScheduler.durations(from: records)
        let unknown = durations.isEmpty ? 1.0
            : (durations.map(\.medianMs).sorted()[durations.count / 2])
        do {
            return try FleetSplit.partition(
                scenarios: selected.map { (id: $0.id, platform: $0.platform) },
                durations: durations,
                entryPlatforms: groups.map(\.platforms),
                unknownDurationMs: unknown,
                entryCapacities: groups.map { Double($0.deviceNames.count) })
        } catch let error as FleetSplit.FleetSplitError {
            throw ValidationError("profile \"\(project.name)\": \(error.localizedDescription)")
        }
    }

    private static func estimateText(_ estimatedMs: Double, devices: Int) -> String {
        let perDevice = estimatedMs / Double(max(devices, 1)) / 1000
        return String(format: "est. %.0fs", perDevice)
    }

    private static func printSummary(profileName: String, outcomes: [FleetEntryOutcome]) {
        FleetRunner.log("")
        FleetRunner.log("=== profile \"\(profileName)\" across machines ===")
        for outcome in outcomes {
            let mark = outcome.exitCode == 0 ? "✅" : "❌"
            FleetRunner.log(String(format: "%@ %-20@ exit=%d  %.1fs", mark, outcome.host as NSString,
                                   outcome.exitCode, outcome.duration))
        }
    }
}
