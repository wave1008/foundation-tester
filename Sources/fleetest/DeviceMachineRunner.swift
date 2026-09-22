// DeviceMachineRunner.swift
// **1つの実行プロファイルのデバイスが複数の機械にまたがるとき**の実行(docs/remote-runner.md §13)。
// 実行プロファイルのデバイスは1台ずつ machine を持てるので、「ローカル10台 + M1Ultra 10台」のような
// 混在が書ける。run はマシンごとのサブ実行(この fleetest 自身の子プロセス)へ分け、シナリオを
// 台数で重み付けして配り、出力・JUnit・終了コードを1つに束ねる。
//
// **フリート(--fleet)との違い**: あちらは「エントリごとに別の実行プロファイル」、こちらは
// 「同じ実行プロファイルをホストごとに担当デバイスだけで」。子プロセスの起動・行の前置・
// JUnit 結合・集計は FleetRunner の同じヘルパを共有する(prefix や中継の実装を二重に持たない)。
//
// 子には `--device <名前…>` と `--runner <ホスト|local>` を渡す。--runner を必ず渡すのは、
// 子が自分で台の machine を読んで再ディスパッチするのを止めるため(FleetRunner と同じ)。

import ArgumentParser
import FTCore
import FTRemote
import Foundation

enum DeviceMachineRunner {

    struct Group: Equatable {
        let machine: String?
        let deviceNames: [String]
        let platforms: Set<String>

        /// 子プロセスへ渡すホスト表記(ローカルは "local")
        var machineLabel: String { DeviceMachineGrouping.display(machine) }
    }

    /// デバイスが2つ以上の機械にまたがっていれば、その分け方を返す。1つ(= 従来どおり全台が
    /// 同じ機械)なら nil を返し、呼び出し側は既存の単一ディスパッチ経路をそのまま通す。
    ///
    /// **`--runner` を明示したときは常に nil** —— 明示指定は「今回はこの機械で走らせる」の意味で、
    /// 分散より強い(MachineDispatch と同じ「明示が勝つ」規律)。「マシン有効」も明示には効かない。
    ///
    /// `disabledMachines`(`MachineEnablement.disabledMachines`)の機械の台は配らない。**1台でも外したら
    /// 残りが1機械でも分割計画を返す** —— nil を返すと単一経路がプロファイルを丸ごと見て、
    /// 外した機械へ自動ディスパッチする/手元でリモートの台を探す。全部外れたら断る
    static func plan(project: TestProject, profileName: String,
                     explicitHost: String?, deviceFilter: [String],
                     disabledMachines: Set<String>) throws -> [Group]? {
        if explicitHost != nil { return nil }
        var devices = ProfileResolver.runDeviceMachines(project: project, runProfileName: profileName)
        if !deviceFilter.isEmpty {
            let wanted = Set(deviceFilter)
            devices = devices.filter { wanted.contains($0.name) }
        }
        let (kept, excluded) = MachineEnablement.partition(devices, disabled: disabledMachines)
        if !excluded.isEmpty {
            guard !kept.isEmpty else {
                throw ValidationError(MachineEnablement.allDisabledMessage(
                    excluded, subject: "hosts run profile \"\(profileName)\"'s devices"))
            }
            // stderr へ(api run の stdout は NDJSON 専用)
            ConsoleOut.err(MachineEnablement.skippedNotice(excluded))
        }
        let grouped = DeviceMachineGrouping.groups(kept) { $0.machine }
        guard grouped.count > 1 || !excluded.isEmpty else { return nil }
        return grouped.map { group in
            Group(machine: group.machine,
                  deviceNames: group.devices.map(\.name),
                  platforms: Set(group.devices.map(\.platform)))
        }
    }

    /// マシンごとのサブ実行を並行に走らせ、1画面の集計を出す。戻り値 = 各サブ実行の非0の最大
    ///
    /// **`failed`/`reportDir` は Fleetest.swift の単機経路(`run()`)と同じ意味の
    /// `--failed`/`--report-dir` をこの分割経路にも適用するためのもの**(欠陥: 以前はここへ
    /// 渡されておらず、複数機械にまたがるプロファイルでは黙って無視されていた)。
    /// **`--failed` は子へ転送しない** —— ここで `selected` を絞ってから機械へ配るので、
    /// 判定はこのマシンの `.fleetest/last-results/` の1回きりで済む(子へ `--failed` も渡すと、
    /// リモート子は**そのランナー自身の last-results**で再判定してしまい、機械ごとに結果がバラつく)。
    /// **`--report-dir` はローカル子だけへ転送する**(`childArgs` 参照。リモート子は
    /// `fleetest run --runner <host>` を経由し、そちらの `dispatchToRemoteHost` が
    /// `--report-dir` を明示的に拒否するため渡すと即 ValidationError で落ちる)
    static func run(
        project: TestProject, profileName: String, groups: [Group],
        scenarios: [String], folders: [String],
        setOverrides: [String: RunProfileSetValue] = [:], noLPT: Bool, lptHistoryRuns: Int?,
        performanceMode: Bool,
        forceLock: Bool, waitLock: Int?, remoteDir: String?, remoteTimeout: Int?,
        quiet: Bool, junit: String?, broadcast: Bool = false,
        failed: Bool = false, reportDir: String? = nil
    ) async throws -> Int32 {
        let junitTempDir = try FleetRunner.makeJUnitTempDir(requested: junit)
        defer { if let junitTempDir { try? FileManager.default.removeItem(at: junitTempDir) } }

        let machineList = groups.map { "\($0.machineLabel)(\($0.deviceNames.count))" }
            .joined(separator: " + ")
        FleetRunner.log("==> profile \"\(profileName)\" spans \(groups.count) machines:"
            + " \(machineList) — building \(project.name) locally to split the scenarios")

        // 機械ごとに別々の run になるので、ここで1回だけ束ね鍵を発行して全員へ配る
        // (FTCore.RunMetaRecord.runGroup。子が自分で作ると束にならない)。ビルドより前に採る ——
        // 待機列のチケット(下)にも使うので、build 分だけ epoch が遅れないようにする
        let runGroup = RunRecorder.makeRunGroupID()
        // dispatch.lock の待機チケットも**ここで1回だけ**採る(DispatchTicketIssuer の宣言。
        // 機械ごとに採り直すと前後関係が機械によって食い違う)。**プロセス環境へも書く**
        // (`FT_DISPATCH_TICKET`。子と同じ綴り・同じ資格で自分自身にも効かせる) —— 下のローカル
        // 先取りと、あとで `DispatchPrelock` が local を取り直すときの両方が、この早い epoch の
        // チケットを引く。書かずに後で採り直すと、build 中に列へ並んだ別 run のチケットのほうが
        // 早い epoch になり、build を終えて戻ってきた自分が FIFO で追い越される
        let ticket = DispatchTicketIssuer.issue(runGroup: runGroup)
        setenv(DispatchTicket.environmentKey, ticket.environmentValue, 1)
        // **この Mac のロックを、ビルド/一覧取得より前に取る**(ユーザー決定 2026-09-21
        // 「1つのマシンで同時に複数の run は走らせない」・規律③「取るのは run の入口」)。
        // **build を直列化するための一時的な先取り** —— 配分が確定したら local に配られるかどうかに
        // 関わらず必ず手放す(下)。全順序どおりの本取得は `DispatchPrelock` が local を含めて
        // 改めて行う(§18.10「循環待ちを構造的に作れない」= local だけ順序の外に出さない)
        var localLock = try LocalDispatchLock(
            runGroup: runGroup, waitLock: waitLock, forceLock: forceLock,
            log: { FleetRunner.log($0) }).acquire()
        defer { localLock?.release() }

        // 割り当てを決めるにはシナリオ一覧が要る(--split と同じ理由でローカルで1回ビルドする)
        try ScenarioHost.build(project: project, log: { FleetRunner.log($0) })
        // 機械分担の run に dry-run は無い(dry-run は手元の run 経路で先に畳まれる)
        let all = try ScenarioHost.listForRun(project: project, dryRun: false)
        guard !all.isEmpty else {
            throw ValidationError(
                "no scenarios (add a @TestClass under TestProjects/\(project.name)/scenarios/)")
        }
        var selected = try ScenarioSelection.resolve(scenarios, from: all)
        if !folders.isEmpty {
            selected = try RunScenarios.filterByFolders(selected, folders: folders,
                                                        scenariosDir: project.scenariosDir)
        }
        guard !selected.isEmpty else {
            throw ValidationError("no scenarios to run after filtering")
        }
        if failed {
            // Fleetest.swift の単機経路と同じ判定・同じ文言(LastResultsStore.failedIDs は
            // (project, profile) 単位。この分割経路もここでしか failed を見ないので1回だけ絞る)
            let failedSet = LastResultsStore.failedIDs(project: project, profile: profileName)
            selected = selected.filter { failedSet.contains($0.id) }
            guard !selected.isEmpty else {
                FleetRunner.log("No scenarios failed last time (everything passed, or nothing has run)")
                return 0
            }
            FleetRunner.log("→ Re-running the \(selected.count) scenario(s) that failed last time")
        }

        let active: [(Int, Group, [String])]
        if broadcast {
            // ブロードキャストは分割しない —— 各機械の各台が全件を回す(分けると「全台で1回ずつ」が
            // 機械ごとの部分集合に化ける)
            let ids = selected.map(\.id)
            active = groups.indices.map { ($0, groups[$0], ids) }
            for (_, group, ids) in active {
                FleetRunner.log("    \(group.machineLabel): \(ids.count) scenario(s)"
                    + " on each of \(group.deviceNames.count) device(s) (--broadcast)")
            }
        } else {
            let (buckets, basis, notApplicable) = try assign(
                project: project, groups: groups, selected: selected, lptHistoryRuns: lptHistoryRuns)
            for line in notApplicableLines(notApplicable, groups: groups) { FleetRunner.log(line) }
            active = groups.indices.compactMap { index -> (Int, Group, [String])? in
                let ids = buckets[index].scenarioIDs
                return ids.isEmpty ? nil : (index, groups[index], ids)
            }
            guard !active.isEmpty else {
                // 全部が対象外なら単機と同じく 0 失敗で終える(正しく緑)
                FleetRunner.log("==> no machine was assigned a scenario; nothing to run")
                return 0
            }
            for (index, group, ids) in active {
                // 推定に続けて**その推定が何に基づいたか**を出す(2026-08-24 受け手要望)。
                // 係数だけ出しても由来が分からないと、遅い機に偏った run を後から検証できない
                FleetRunner.log("    \(group.machineLabel): \(ids.count) scenario(s)"
                    + " on \(group.deviceNames.count) device(s)"
                    + " [\(buckets[index].estimatedMs > 0 ? estimateText(buckets[index].estimatedMs, devices: group.deviceNames.count) : "no history")"
                    + "; \(basis[index].summary)]")
            }
        }

        // 配分が確定したら、build 直列化のために先取りしたロックは**local に配られたかどうかに
        // 関わらず**必ず手放す(下の DispatchPrelock が local を含めて全順序どおり取り直すため。
        // 手放さずに残すと local だけ順序の外に出た「取得済み」扱いになり、循環待ちを作れる形へ戻る)
        localLock?.release()
        localLock = nil

        // 手元の台の二重使用は**どの機械へも配る前に**断る(ProfileRunner.rejectIfLocalDevicesLeasedBeforeDispatch)。
        // **dispatch.lock より手前なのは意図**(読み取りだけの先読み。上の localLock は既に
        // 手放し済みなので、ここでは何も持っていない。理由は FTBridgeClient/RunLeaseGuard.swift の冒頭)
        if let local = active.first(where: { $0.1.machine == nil }) {
            let ids = Set(local.2)
            try ProfileRunner.rejectIfLocalDevicesLeasedBeforeDispatch(
                project: project, profileName: profileName, setOverrides: setOverrides,
                localDeviceNames: local.1.deviceNames,
                localScenarios: selected.filter { ids.contains($0.id) }, broadcast: broadcast,
                waitLock: waitLock, log: { FleetRunner.log($0) })
        }

        let binary = FleetRunner.selfBinaryPath()
        // **親が機械の全順序どおりに1台ずつ取り切ってから子を起こす**(DispatchPrelock。local も
        // 他の機械と同じ扱いで、上で発行し環境へ書いたチケットを引く)
        let prelock = DispatchPrelock(actions: DispatchPrelock.live(
            project: project, remoteDir: remoteDir, forceLock: forceLock, waitLock: waitLock,
            runGroup: runGroup, mode: .cliRun, log: { FleetRunner.log($0) }))
        defer { prelock.releaseAll() }
        prelock.acquireInOrder(machines: DispatchPrelock.machinesToLock(
            active.map { $0.1.machineLabel }))
        // 子タスクへ渡すのは値のコピー(prelock 自身を @Sendable な closure へ持ち込まない)
        let lockMarkers = prelock.markers
        // サブ実行のクラッシュ検出(reportMissingResults)が「この run で書かれた記録」を
        // 走査の窓で絞るための開始時刻。子の起動より前に捕まえる(子の書き込みは必ずこの後)
        let dispatchStart = Date()
        let outcomes = await withTaskGroup(of: (Int, FleetEntryOutcome).self) { taskGroup in
            for (index, group, ids) in active {
                taskGroup.addTask {
                    let args = childArgs(
                        project: project.name, host: group.machineLabel, profile: profileName,
                        deviceNames: group.deviceNames, deviceMachine: group.machineLabel,
                        scenarios: ids, folders: [],
                        setOverrides: setOverrides, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
                        performanceMode: performanceMode, forceLock: forceLock,
                        remoteDir: remoteDir, remoteTimeout: remoteTimeout,
                        quiet: quiet,
                        junitPath: FleetRunner.entryJUnitPath(tempDir: junitTempDir, index: index),
                        broadcast: broadcast, runGroup: runGroup, reportDir: reportDir)
                    let start = Date()
                    let exitCode = await FleetRunner.runEntry(
                        binary: binary, args: args, hostLabel: group.machineLabel, ticket: ticket,
                        lockMarker: lockMarkers[group.machineLabel])
                    return (index, FleetEntryOutcome(
                        host: group.machineLabel, profile: profileName, exitCode: exitCode,
                        duration: Date().timeIntervalSince(start)))
                }
            }
            var collected: [Int: FleetEntryOutcome] = [:]
            for await (index, outcome) in taskGroup { collected[index] = outcome }
            return active.compactMap { collected[$0.0] }
        }

        printSummary(profileName: profileName, outcomes: outcomes)
        // **broadcast はここを呼ばない** —— 同じ ID を台数ぶん走らせるので、1台でも記録が
        // あれば「走った」であり「欠落」の意味が変わる(呼び手で分岐。実装を分けない)
        if !broadcast {
            reportMissingResults(project: project, profileName: profileName, runGroup: runGroup,
                                 since: dispatchStart, active: active, outcomes: outcomes)
        }
        // ディスパッチした(= --junit を渡した)ぶんだけ結合する。0本で見送ったホストを混ぜると
        // 「出力が無い」合成失敗になり、走らせてもいないものが赤くなる(FleetRunner と同じ規律)
        if let junit, let junitTempDir {
            FleetRunner.mergeAndWriteJUnit(
                junit: junit, project: project.name, tempDir: junitTempDir,
                entries: active.map { (host: $0.1.machineLabel, index: $0.0) })
        }
        return FleetProfile.aggregateExitCode(outcomes.map(\.exitCode))
    }

    /// マシン別サブ実行1本分の引数(純粋関数。単体テスト対象)。`FleetRunner.buildArgs`
    /// (--fleet と共有するヘルパー。--fleet は `--report-dir`/`--skip-build` と併用不可なので
    /// これらをそちらへは足さない)に、この分割経路だけが必要とする2つを追加する:
    /// **`--skip-build`(ローカル子だけ)** —— `run()` が呼び出し元で1回だけローカルビルド済み
    /// (`ScenarioHost.build`)なので、ローカル子に省略させないと同じビルドを2回払う。リモート子は
    /// 別マシンなので自分でビルドさせる(常に省略しない)。
    /// **`--report-dir`(ローカル子だけ)** —— リモート子は `dispatchToRemoteHost` を経由し、
    /// そちらは `--report-dir` を明示的に拒否する(Fleetest.swift の RemoteDispatchFlagPolicy)。
    /// 渡すとリモート枠のサブ実行が ValidationError で即落ちるので、ローカル子にしか渡さない
    static func childArgs(
        project: String, host: String, profile: String,
        deviceNames: [String] = [], deviceMachine: String? = nil,
        scenarios: [String], folders: [String],
        setOverrides: [String: RunProfileSetValue] = [:], noLPT: Bool, lptHistoryRuns: Int?,
        performanceMode: Bool,
        forceLock: Bool, remoteDir: String?, remoteTimeout: Int?,
        quiet: Bool, junitPath: String?, broadcast: Bool = false, runGroup: String? = nil,
        reportDir: String? = nil
    ) -> [String] {
        var args = FleetRunner.buildArgs(
            project: project, host: host, profile: profile,
            deviceNames: deviceNames, deviceMachine: deviceMachine,
            scenarios: scenarios, folders: folders,
            setOverrides: setOverrides, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
            performanceMode: performanceMode, forceLock: forceLock,
            remoteDir: remoteDir, remoteTimeout: remoteTimeout,
            quiet: quiet, junitPath: junitPath, broadcast: broadcast, runGroup: runGroup)
        if host == "local" {
            args += ["--skip-build"]
            if let reportDir { args += ["--report-dir", reportDir] }
        }
        return args
    }

    // MARK: - 割り当て

    /// 実績(results)からの見積りで LPT 分割する。**重みは台数**(同時に回せる本数)——
    /// 総量で均すと台数の少ないホストが最後まで残る。実績が1件も無ければ全員同じ重みになり、
    /// 台数比での本数割りに退化する(FleetRunner.unknownDurationUnitWeight と同じ考え方)。
    /// internal: ApiRunMachineFanout も同じ割り当てを使う(二重実装しない)。
    /// **宣言 platform の台がどの機械にも無いシナリオは対象外**(notApplicable)として割り当てから
    /// 外して返す(単機の ProfileRunner と同じ規律。FleetSplit.applicability の宣言)。呼び手は
    /// 単機と同じ文言でスキップを出す。子 run には渡さない —— api 経路の MachineFanoutMultiplexer は
    /// 子に渡した ID のうちイベントが来なかったものを failed に合成するため、渡すと赤になる
    static func assign(project: TestProject, groups: [Group],
                       selected: [ScenarioInfo], lptHistoryRuns: Int?)
        throws -> (buckets: [FleetSplit.Bucket], basis: [FleetSplit.EstimateBasis],
                   notApplicable: [ScenarioInfo]) {
        let split = FleetSplit.applicability(
            scenarios: selected.map { (id: $0.id, platform: $0.platform) },
            entryPlatforms: groups.map(\.platforms))
        let runnableIDs = Set(split.runnable.map(\.id))
        let runnable = selected.filter { runnableIDs.contains($0.id) }
        let notApplicable = selected.filter { !runnableIDs.contains($0.id) }
        let historyRuns = max(1, lptHistoryRuns ?? LPTOrdering.defaultHistoryRuns)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        let since = Date().addingTimeInterval(-30 * 24 * 60 * 60)  // LPTOrdering.historyDays と同じ窓
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: since,
                                                  maxObservationsPerScenario: historyRuns)
        let durations = LPTScheduler.durations(from: records)
        let unknown = durations.isEmpty ? 1.0
            : (durations.map(\.medianMs).sorted()[durations.count / 2])
        // facts はディスパッチのたびに RemoteRunDispatcher が書く。初回(キャッシュ無し)は
        // machine=nil・offset=0 で MachineContext が従来の混合見積りへ退化する(FleetRunner と同じ)。
        // entryFallbackFactors(実績が無い機械の事前係数)の考え方は FleetRunner.buildMachineContext
        // のコメント参照(二重に書かない)
        let factsDir = RemoteHostFactsStore.dir(project: project)
        // **鍵はホスト(ssh 宛先)**。ローカルエイリアスは変わりうるので使わない(RemoteHostFacts)
        let registry = LocalConfig.load().remoteHosts ?? []
        let localHost = RunRecorder.currentMachine()
        let groupFacts: [RemoteHostFacts?] = groups.map { group in
            guard group.machine != nil else { return nil }
            return RemoteHostFactsStore.load(
                dir: factsDir,
                host: RemoteHostFactsStore.hostKey(machine: group.machine, entries: registry,
                                                   localHost: localHost))
        }
        let entryMachines: [String?] = zip(groups, groupFacts).map { group, facts in
            group.machine == nil ? localHost : facts?.host
        }
        let entryFixedOffsetsMs = groupFacts.map { ($0?.dispatchOverheadSeconds ?? 0) * 1000 }
        let localHardware = MachineHardware.current()
        let entryFallbackFactors: [Double] = zip(groups, groupFacts).map { group, facts in
            guard group.machine != nil else { return 1.0 }
            guard let coreCount = facts?.coreCount, coreCount > 0 else { return 1.0 }
            return Double(localHardware.coreCount) / Double(coreCount)
        }
        saveLocalHostFacts(project: project, hardware: localHardware, groups: groups)
        let machineContext = FleetSplit.MachineContext(
            entryMachines: entryMachines, entryFixedOffsetsMs: entryFixedOffsetsMs,
            machineDurations: LPTScheduler.machineDurations(from: records),
            entryFallbackFactors: entryFallbackFactors)
        do {
            let plan = try FleetSplit.plan(
                scenarios: runnable.map { (id: $0.id, platform: $0.platform) },
                durations: durations,
                entryPlatforms: groups.map(\.platforms),
                unknownDurationMs: unknown,
                entryCapacities: groups.map { Double($0.deviceNames.count) },
                // 実績ゼロ = unknown が単位重みのときは context を落とす(FleetRunner と同じ理由)
                machineContext: FleetSplit.machineContext(machineContext, ifHistoryExists: durations))
            return (plan.buckets, plan.basis, notApplicable)
        } catch let error as FleetSplit.FleetSplitError {
            throw ValidationError("profile \"\(project.name)\": \(error.localizedDescription)")
        }
    }

    /// 単機の ProfileRunner が出すスキップ行と同じ内容(1行の集計 + 1本ずつの理由)
    static func notApplicableLines(_ notApplicable: [ScenarioInfo], groups: [Group]) -> [String] {
        guard !notApplicable.isEmpty else { return [] }
        let runPlatforms = FleetSplit.runPlatforms(entryPlatforms: groups.map(\.platforms))
        var lines = ["→ Skipped \(notApplicable.count) scenario(s) declared for another platform"
            + " (this profile covers \(runPlatforms.sorted().joined(separator: ", ")))"]
        for info in notApplicable {
            lines.append("    \(info.id): "
                + PlatformApplicability.reason(declared: info.platform ?? "", runPlatforms: runPlatforms))
        }
        return lines
    }

    /// FleetRunner.buildMachineContext の同名ヘルパと同じ規律(手元の鍵で facts を保存、
    /// dispatchOverheadSeconds は既存値を保持)。こちらは local グループの台数が分かるので
    /// concurrentDevices も埋める。**鍵はこの機械のホスト名**("local" ではない ——
    /// エイリアスも予約名も記録の鍵にしない。2026-08-26 ユーザー決定)
    private static func saveLocalHostFacts(project: TestProject, hardware: MachineHardware, groups: [Group]) {
        let dir = RemoteHostFactsStore.dir(project: project)
        let localHost = RunRecorder.currentMachine()
        let existing = RemoteHostFactsStore.load(dir: dir, host: localHost)
        let localDeviceCount = groups.first(where: { $0.machine == nil })?.deviceNames.count
        let facts = RemoteHostFacts(
            host: localHost,
            // 手元の表示名は "local"(FTCore.DeviceMachineGrouping.localDisplayName)
            machineAlias: DeviceMachineGrouping.localDisplayName,
            dispatchOverheadSeconds: existing?.dispatchOverheadSeconds,
            processorModel: hardware.processorModel, coreCount: hardware.coreCount,
            concurrentDevices: localDeviceCount ?? existing?.concurrentDevices,
            updatedAt: ISO8601DateFormatter().string(from: Date()))
        RemoteHostFactsStore.save(facts, dir: dir, host: localHost)
    }

    // MARK: - 結果の無いシナリオ(サブ実行のクラッシュ)

    /// サブ実行がクラッシュ/強制終了すると、担当していたシナリオの一部が結果を1件も残さないまま
    /// 終わることがある(実測: `run --runner local` を SIGKILL → 11 本中 9 本が run.json に
    /// finishedAt 無し・scenarios は 2 件だけ)。**`--failed` の記録は回収できたシナリオ JSON
    /// からしか書かれない**(`RemoteRunDispatcher.writeLastResults` と同じ口)ので、結果の無い分は
    /// 前回(緑)の記録のまま残り、黙って再実行の対象から外れる。ここで欠落を1行で知らせた上で
    /// `LastResultsStore` へ失敗として記録し、次回の `--failed` が拾えるようにする
    private static func reportMissingResults(
        project: TestProject, profileName: String, runGroup: String, since: Date,
        active: [(Int, Group, [String])], outcomes: [FleetEntryOutcome]
    ) {
        let recorded = scanRecordedScenarios(project: project, runGroup: runGroup, since: since)
        // **順序ではなく machineLabel で引く**: outcomes は今は active と同じ順序で作られているが、
        // その保証は run() の集計の実装詳細なので、崩れたときに「別の機械の exit code」を
        // 名指しする形にしない(引けなければ exit code 不明として 0 以外を意味する -1)
        let exitCodes = Dictionary(outcomes.map { ($0.host, $0.exitCode) }, uniquingKeysWith: { first, _ in first })
        for (_, group, ids) in active {
            let exitCode = exitCodes[group.machineLabel] ?? -1
            let missing = unrecordedScenarioIDs(assigned: ids, recorded: recorded.all)
            if !missing.isEmpty {
                FleetRunner.log(missingResultsLine(
                    machineLabel: group.machineLabel, exitCode: exitCode, ids: missing))
                for id in missing {
                    LastResultsStore.record(project: project, scenarioID: id, passed: false, profile: profileName)
                }
            }
            // M7b: 中断された記録は「記録あり」に数えられて missing に出ない(missing は「1件も
            // 記録が無い」だけを見る)ので、別枠で知らせる。**exit code 0(正常終了)では出さない**
            // (中断済みの記録が残るのは異常終了経路(ssh の断・kill 等)だけの想定。実測 2026-09-17:
            // リモート機は中断を受け取って scenarios/*.json に interrupted: true で書いたが、
            // 手元は「記録あり」としか見ておらず、その1本は画面にも exit=137 のログにも一度も出なかった)
            guard exitCode != 0 else { continue }
            let interrupted = ids.filter { recorded.interrupted.contains($0) }
            guard !interrupted.isEmpty else { continue }
            FleetRunner.log(interruptedResultsLine(
                machineLabel: group.machineLabel, exitCode: exitCode, ids: interrupted))
        }
    }

    /// scanRuns の `since` はその run の `startedAt`(その機械自身の時計)と直接比較される。
    /// リモート機の時計がこの機械よりわずかに遅れていると、実際にはこの run の子が書いた
    /// run.json が `since` 未満に見えて丸ごと除外され、その機械の全シナリオが「欠落」と
    /// 誤判定されかねない。**判定の実体は runGroup の一致**(ほぼ確実に一意な発番)なので、
    /// `since` は走査量を絞るための粗い窓でよく、NTP 未同期でも通常収まる範囲としてマージンを取る
    /// (これを超えるズレは `FTAndroid.AndroidHealthProbe.issueClockSkew` が別途検知する領域)
    private static let clockSkewMargin: TimeInterval = 5 * 60

    /// この run(runGroup)に属する run ディレクトリの `scenarios/*.json` から集計した記録。
    /// `all` = 記録があった scenarioID 全部、`interrupted` = そのうち `record.interrupted == true`
    /// だったもの(サブ実行が ssh の断・kill 等で終わり、リモート側が「中断」として書いた途中版が
    /// 回収されたケース。M7b)
    struct RecordedScenarios {
        var all: Set<String> = []
        var interrupted: Set<String> = []
    }

    /// **ファイル名でなく JSON の中身で照合する**(日本語ファイル名は NFD 保存で glob・文字列一致が
    /// 静かに外れる実害あり)。呼び手を増やしても scanRuns の走査を2回払わないよう、
    /// all/interrupted は1回の走査でまとめて集計する
    static func scanRecordedScenarios(project: TestProject, runGroup: String, since: Date) -> RecordedScenarios {
        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        let metas = RunResultsStore.scanRuns(resultsDir: resultsDir,
                                             since: since.addingTimeInterval(-clockSkewMargin))
            .filter { $0.runGroup == runGroup }
        var result = RecordedScenarios()
        for meta in metas {
            let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: meta.runID)
            for record in RunResultsStore.records(runDir: runDir) {
                result.all.insert(record.scenarioID)
                if record.interrupted == true { result.interrupted.insert(record.scenarioID) }
            }
        }
        return result
    }

    /// `all` だけでよい呼び手向け(unrecordedScenarioIDs の入力)
    static func recordedScenarioIDs(project: TestProject, runGroup: String, since: Date) -> Set<String> {
        scanRecordedScenarios(project: project, runGroup: runGroup, since: since).all
    }

    /// `assigned` のうち `recorded` に無い ID(順序は assigned のまま)。純粋関数(単体テスト対象)
    static func unrecordedScenarioIDs(assigned: [String], recorded: Set<String>) -> [String] {
        assigned.filter { !recorded.contains($0) }
    }

    /// 「結果が1件も無かった」ことを知らせる1行(純粋関数。単体テスト対象)。
    /// 5件を超えたら先頭5件 + "…" に切る(負荷テストの実測で1機に11本の割り当ては普通に起きる。
    /// 全件出すとログが埋まる。件数自体は先頭の "N scenario(s)" に必ず出る)
    static func missingResultsLine(machineLabel: String, exitCode: Int32, ids: [String]) -> String {
        let maxListed = 5
        let listed = ids.prefix(maxListed).joined(separator: ", ")
        let suffix = ids.count > maxListed ? ", …" : ""
        return "⚠️ \(machineLabel): \(ids.count) scenario(s) produced no result"
            + " (sub-run exited \(exitCode)): \(listed)\(suffix)"
    }

    /// 「記録はあるが中断されたまま残った」ことを知らせる1行(純粋関数。単体テスト対象)。
    /// missingResultsLine と同じ5件で切る規則。**呼び出し側が exit code 0 では呼ばないこと**
    /// (正常終了で中断記録が残ることは無い想定)
    static func interruptedResultsLine(machineLabel: String, exitCode: Int32, ids: [String]) -> String {
        let maxListed = 5
        let listed = ids.prefix(maxListed).joined(separator: ", ")
        let suffix = ids.count > maxListed ? ", …" : ""
        return "⚠️ \(machineLabel): \(ids.count) scenario(s) were interrupted"
            + " (sub-run exited \(exitCode)): \(listed)\(suffix)"
    }

    private static func estimateText(_ estimatedMs: Double, devices: Int) -> String {
        let perDevice = estimatedMs / Double(max(devices, 1)) / 1000
        return String(format: "est. %.0fs", perDevice)
    }

    private static func printSummary(profileName: String, outcomes: [FleetEntryOutcome]) {
        FleetRunner.log("")
        FleetRunner.log("=== profile \"\(profileName)\" across machines ===")
        // 静的割り当ての偏り(ストラグラー)を再配分機構を作る前に実測で貯める
        let maxDuration = outcomes.map(\.duration).max() ?? 0
        for outcome in outcomes {
            let mark = outcome.exitCode == 0 ? "✅" : "❌"
            FleetRunner.log(String(format: "%@ %-20@ exit=%d  %.1fs idle=%.1fs", mark,
                                   outcome.host as NSString, outcome.exitCode, outcome.duration,
                                   maxDuration - outcome.duration))
        }
    }
}
