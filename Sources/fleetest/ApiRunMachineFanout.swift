// ApiRunMachineFanout.swift
// `fleetest api run --profile <p>` で p のデバイスが複数の機械にまたがるときの実行
// (docs/remote-runner.md §13)。DeviceMachineRunner(`fleetest run` の同じ状況)と同じ割り当て
// (build→list→resolve→assign)を再利用し、ホストごとに `fleetest api run --host <label> …` を
// 子プロセスとして並行に起動、NDJSON を1本の stdout ストリームへ多重化する。
//
// 拡張(vscode-fleetest/src/model.ts)は「1本の NDJSON = runStarted → workersReady →
// (各種イベント) → runFinished」という契約しか知らない。子1つにつき1本ずつ来る同じ形の
// ストリームを、runStarted/runFinished は集計してこちらが1回だけ出し、workersReady は
// **子ごとに届くたび**それまでの累積(子 index 順)で合成して出し直し、それ以外は worker
// フィールドをホスト付き id(FTCore.DeviceMachineGrouping.workerID)へ書き換えて**即時**中継する
// (バッファしない = リモート機の準備待ちでローカル分の表示が止まらない。2026-08-18)。
// 子が担当シナリオを残して終了したら、そのシナリオを failed として合成イベントで報告する。

import ArgumentParser
import FTCore
import Foundation

enum ApiRunMachineFanout {

    /// 子プロセスへ素通しするオプション。skipBuild/folders は無い —— ビルドは常にここで1回だけ
    /// 行う(DeviceMachineRunner.run と同じ理由。シナリオ一覧が割り当てに要る)。--report-dir は
    /// 意図的に含めない: リモートホストの子は `dispatchToRemoteHost` が --report-dir を
    /// 常に拒否するため(RemoteDispatchFlagPolicy.rejected)、一部のホストにだけ効く/効かないが
    /// 混在する形になる。CLI 側の多機械ディスパッチ(DeviceMachineRunner/FleetRunner)も同じ理由で
    /// --report-dir を子へ渡していない(既存の踏襲)
    struct Options {
        var heal: Bool
        var defaultTimeout: Double?
        var scenarioTimeout: Int?
        var noLPT: Bool
        var lptHistoryRuns: Int?
        var performanceMode: Bool
        var remoteDir: String?
        var remoteTimeout: Int?
        var remoteArtifacts: String
    }

    /// 戻り値 = FleetProfile.aggregateExitCode(各ホストの exit code の集約)
    static func run(
        project: TestProject, profileName: String, groups: [DeviceMachineRunner.Group],
        scenarios: [String], options: Options
    ) async throws -> Int32 {
        let machineList = groups.map { "\($0.machineLabel)(\($0.deviceNames.count))" }.joined(separator: " + ")
        logStderr("==> profile \"\(profileName)\" spans \(groups.count) machines: \(machineList)"
            + " — building \(project.name) locally to split the scenarios")

        // 割り当てを決めるにはシナリオ一覧が要る(DeviceMachineRunner.run と同じ理由。ここで1回だけ
        // ローカルビルドする。ローカルの子には --skip-build を渡す = 下の buildChildArgs 参照)
        try ScenarioHost.build(project: project) { logStderr($0) }
        let all = try ScenarioHost.list(project: project)
        guard !all.isEmpty else {
            throw ValidationError(
                "no scenarios (add a @TestClass under TestProjects/\(project.name)/scenarios/)")
        }
        let selected = try RunScenarios.resolve(scenarios, from: all)
        guard !selected.isEmpty else {
            throw ValidationError("no scenarios to run after filtering")
        }

        let (buckets, basis, notApplicable) = try DeviceMachineRunner.assign(
            project: project, groups: groups, selected: selected,
            lptHistoryRuns: options.lptHistoryRuns)
        for line in DeviceMachineRunner.notApplicableLines(notApplicable, groups: groups) { logStderr(line) }
        let active = groups.indices.compactMap { index -> (index: Int, group: DeviceMachineRunner.Group, ids: [String])? in
            let ids = buckets[index].scenarioIDs
            return ids.isEmpty ? nil : (index, groups[index], ids)
        }
        // CLI と同じ「見積りの根拠」を拡張の OUTPUT にも出す(片方だけ見える情報を作らない)
        for (index, group, ids) in active {
            logStderr("    \(group.machineLabel): \(ids.count) scenario(s)"
                + " on \(group.deviceNames.count) device(s) [\(basis[index].summary)]")
        }
        let dispatchStart = Date()
        // 全部が宣言 platform の対象外なら単機の run と同じく 0/0 で終える(正しく緑)。
        // それ以外で全滅(= 対象外でもないのに割り当て 0)は FleetSplit.partition が設定ミスとして
        // throw 済みなので、ここへは来ない
        guard !active.isEmpty else {
            writeLine(encode(ApiRunStartedEvent(total: 0)))
            writeLine(encode(ApiRunFinishedEvent(
                passed: 0, failed: 0,
                testSeconds: Date().timeIntervalSince(dispatchStart), scenarioTotalSeconds: nil)))
            return 0
        }
        for (_, group, ids) in active {
            logStderr("    \(group.machineLabel): \(ids.count) scenario(s) on \(group.deviceNames.count) device(s)")
        }

        // total は対象外を除いた本数(単機の ApiRunCommand と同じ: スキップは runStarted に数えない)
        writeLine(encode(ApiRunStartedEvent(total: selected.count - notApplicable.count)))

        let binary = FleetRunner.selfBinaryPath()
        // 束ね鍵はここで1回だけ発行する(理由は DeviceMachineRunner.run の同じ箇所)
        let runGroup = RunRecorder.makeRunGroupID()
        let (stream, continuation) = AsyncStream<ChildEvent>.makeStream()
        let groupMachines = active.map { $0.group.machine }

        // 拡張のキャンセル(SIGTERM/SIGINT)・stdin EOF のどちらでも全子へ SIGTERM を送る。
        // 子(単発の `fleetest api run --host <label>`)は自分ではシグナルを捕まえないので既定の
        // 即時終了になり、リモート子はその内部の ssh(-tt 付き)が親の死で SIGHUP を孫プロセスへ
        // 伝える(RemoteRunDispatcher.sshRunBase の宣言と同じ機構)。単発 `api run --host` は
        // 自分自身が拡張の直接の子なので OS がこの経路で保護するが、ここは**この fanout が
        // 増やした孫プロセス**を対象にする(既存の保護の外側)
        let registry = ChildProcessRegistry()

        // assignedScenarioIDs は active と同じ並び(下の taskGroup が position をそのまま
        // childIndex として runChild へ渡すのと同じ基準)。isCancelled はキャンセル後の
        // 合成 failed を抑止する(キャンセルで子は非0終了するため、抑止しないと中断した
        // シナリオが failed として赤く出る。キャンセル≠失敗)
        async let multiplexed = consume(
            stream: stream, groupMachines: groupMachines, assignedScenarioIDs: active.map { $0.ids },
            isCancelled: { registry.isCancelled })
        let cancelSources = installCancellation(registry: registry)
        defer { for source in cancelSources { source.cancel() } }

        let outcomes = await withTaskGroup(of: (Int, FleetEntryOutcome).self) { taskGroup in
            for (position, entry) in active.enumerated() {
                let (_, group, ids) = entry
                taskGroup.addTask {
                    let args = buildArgs(
                        project: project.name, profileName: profileName, group: group,
                        scenarioIDs: ids, options: options, runGroup: runGroup)
                    let start = Date()
                    let exitCode = await runChild(
                        index: position, binary: binary, args: args, machineLabel: group.machineLabel,
                        continuation: continuation, registry: registry)
                    return (position, FleetEntryOutcome(
                        host: group.machineLabel, profile: profileName, exitCode: exitCode,
                        duration: Date().timeIntervalSince(start)))
                }
            }
            var collected: [Int: FleetEntryOutcome] = [:]
            for await (position, outcome) in taskGroup { collected[position] = outcome }
            return (0..<active.count).compactMap { collected[$0] }
        }
        // 全子が最後の .exited を継続へ渡し終えたあとでのみ finish してよい(withTaskGroup は
        // 各子タスクの return を待つので、この時点で runChild は必ず .exited を yield 済み)
        continuation.finish()

        let (totalPassed, totalFailed) = await multiplexed
        writeLine(encode(ApiRunFinishedEvent(
            passed: totalPassed, failed: totalFailed,
            testSeconds: Date().timeIntervalSince(dispatchStart), scenarioTotalSeconds: nil)))

        logStderr("")
        logStderr("=== profile \"\(profileName)\" across machines ===")
        for outcome in outcomes {
            let mark = outcome.exitCode == 0 ? "✅" : "❌"
            logStderr(String(format: "%@ %-20@ exit=%d  %.1fs", mark, outcome.host as NSString,
                             outcome.exitCode, outcome.duration))
        }
        return FleetProfile.aggregateExitCode(outcomes.map(\.exitCode))
    }

    // MARK: - 子プロセスの引数

    /// internal: 束ね鍵の中継を RunGroupPlumbingTests が等号で固定する
    static func buildArgs(
        project: String, profileName: String, group: DeviceMachineRunner.Group,
        scenarioIDs: [String], options: Options, runGroup: String
    ) -> [String] {
        let machineLabel = group.machineLabel
        var args = ["api", "run", "--project", project, "--profile", profileName]
        // **常に --host を渡す**(FleetRunner.buildArgs と同じ理由: 省略すると子が自分でマシン
        // プロファイルの host を再解決してしまう。"local" は MachineDispatch.resolve が
        // 明示指定として止める)
        args += ["--machine", machineLabel]
        // **--skip-build はローカル子だけ**(dispatchToRemoteHost が .explicitHost origin では
        // "--skip-build is not supported with --host" で拒否する。RemoteDispatchFlagPolicy.skipBuild
        // の宣言参照。リモートは自前でビルドするので、渡す必要も無い)
        if machineLabel == DeviceMachineGrouping.localDisplayName {
            args += ["--skip-build"]
        } else {
            if let remoteDir = options.remoteDir { args += ["--remote-dir", remoteDir] }
            if let remoteTimeout = options.remoteTimeout { args += ["--remote-timeout", String(remoteTimeout)] }
            if options.remoteArtifacts != "collect" { args += ["--remote-artifacts", options.remoteArtifacts] }
        }
        // **ホストも渡す**(一意なのは (host, name)。ApiRunCommand.deviceMachine の宣言参照)
        args += ["--device"] + group.deviceNames
        args += ["--device-machine", machineLabel]
        args += ["--scenario"] + scenarioIDs
        if options.heal { args += ["--heal"] }
        if options.noLPT { args += ["--no-lpt"] }
        if let lptHistoryRuns = options.lptHistoryRuns { args += ["--lpt-history-runs", String(lptHistoryRuns)] }
        if options.performanceMode { args += ["--performance"] }
        if let defaultTimeout = options.defaultTimeout { args += ["--default-timeout", String(defaultTimeout)] }
        if let scenarioTimeout = options.scenarioTimeout { args += ["--scenario-timeout", String(scenarioTimeout)] }
        args += ["--run-group", runGroup]
        return args
    }

    // MARK: - 子プロセス

    private enum ChildEvent {
        case line(index: Int, text: String)
        case exited(index: Int, status: Int32)
    }

    /// 子1体ぶん。stdout(NDJSON)は行単位で continuation へ、stderr(診断)はホスト名を前置して
    /// そのまま親の stderr へ流す(stdout は NDJSON 専用の契約なので混ぜない)
    private static func runChild(
        index: Int, binary: String, args: [String], machineLabel: String,
        continuation: AsyncStream<ChildEvent>.Continuation, registry: ChildProcessRegistry
    ) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let exitStream = ProcessExitWait.prepare(process)
        do {
            try process.run()
        } catch {
            logStderr("[\(machineLabel)] error: failed to launch subprocess: \(error.localizedDescription)")
            continuation.yield(.exited(index: index, status: 127))
            return 127
        }
        registry.register(process)

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutDone = DispatchSemaphore(value: 0)
        let stderrDone = DispatchSemaphore(value: 0)
        let stdoutSplitter = StreamLineSplitter()
        let stderrSplitter = StreamLineSplitter()

        DispatchQueue.global(qos: .utility).async {
            while true {
                // readData(ofLength:) は length か EOF まで返らない(パイプでは子の終了まで
                // 全量が貯まり、ライブ中継が子の exit 時の一括になる。availableData は
                // 届いた分だけ返す。2026-08-18 実測)
                let chunk = stdoutHandle.availableData
                if chunk.isEmpty { break }
                for line in stdoutSplitter.feed(chunk) { continuation.yield(.line(index: index, text: line)) }
            }
            stdoutDone.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = stderrHandle.availableData  // 上と同じ理由(readData は EOF まで貯める)
                if chunk.isEmpty { break }
                for line in stderrSplitter.feed(chunk) { logStderr("[\(machineLabel)] \(line)") }
            }
            stderrDone.signal()
        }

        for await _ in exitStream {}
        stdoutDone.wait()
        stderrDone.wait()
        if let remaining = stdoutSplitter.flush() { continuation.yield(.line(index: index, text: remaining)) }
        if let remaining = stderrSplitter.flush() { logStderr("[\(machineLabel)] \(remaining)") }
        continuation.yield(.exited(index: index, status: process.terminationStatus))
        return process.terminationStatus
    }

    // MARK: - キャンセル(孤児の ssh/子 run を残さない)

    /// 生きている子プロセスの集合。register() より前に cancel 済みなら、その場で即終了させる
    /// (シグナル到着とプロセス起動が競合しても取りこぼさない)
    private final class ChildProcessRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [Process] = []
        private var cancelled = false

        func register(_ process: Process) {
            lock.lock()
            let alreadyCancelled = cancelled
            if !alreadyCancelled { processes.append(process) }
            lock.unlock()
            if alreadyCancelled, process.isRunning { process.terminate() }
        }

        func terminateAll() {
            lock.lock()
            cancelled = true
            let toKill = processes
            lock.unlock()
            for process in toKill where process.isRunning { process.terminate() }
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    /// SIGTERM・SIGINT で registry.terminateAll() を呼ぶ(ApiLiveServe/ApiMonitorCommand と
    /// 同じ規律: DispatchSourceSignal を使うには先に SIG_IGN が要る)。拡張のキャンセルは
    /// SIGTERM(vscode-fleetest/src/cli.ts の proc.kill)なのでこれで届く。
    /// 戻り値は子の待機が終わるまで保持すること(解放されるとハンドラが外れる)。
    ///
    /// **stdin の EOF を打ち切りの合図に使ってはいけない** —— `api run` は --debug 以外
    /// stdin を読まず、拡張は stdio[0] を "ignore"(= /dev/null)で起動する。EOF を見ると
    /// 起動と同時に全子プロセスを殺すことになる(実際にそうなり、拡張からの実行が
    /// 開始直後に exit=15 で全滅した)
    private static func installCancellation(registry: ChildProcessRegistry) -> [DispatchSourceSignal] {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let queue = DispatchQueue(label: "fleetest-api-run-fanout-signal")
        return [SIGTERM, SIGINT].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { registry.terminateAll() }
            source.resume()
            return source
        }
    }

    // MARK: - 多重化(I/O 側。純粋な状態機械は MachineFanoutMultiplexer)

    private static func consume(
        stream: AsyncStream<ChildEvent>, groupMachines: [String?], assignedScenarioIDs: [[String]],
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> (passed: Int, failed: Int) {
        var multiplexer = MachineFanoutMultiplexer(groupMachines: groupMachines, assignedScenarioIDs: assignedScenarioIDs)
        for await event in stream {
            switch event {
            case .line(let index, let text):
                for line in multiplexer.ingest(childIndex: index, line: text) { writeLine(line) }
            case .exited(let index, let status):
                // キャンセルで殺された子の未完了は合成しない(キャンセル≠失敗)
                guard !isCancelled() else { continue }
                for line in multiplexer.childExited(index, exitCode: status) { writeLine(line) }
            }
        }
        return (multiplexer.totalPassed, multiplexer.totalFailed)
    }

    // MARK: - 出力(FleetRunner.log/logLine と同じ規律。stdout は NDJSON 専用・行単位で lock)

    private static let stdoutLock = NSLock()

    private static func writeLine(_ line: String) {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static let stderrLock = NSLock()

    private static func logStderr(_ message: String) {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return #"{"kind":"log","message":"(encode error)"}"#
        }
        return text
    }
}

/// 子の NDJSON を1本へ多重化する状態機械(純粋・プロセス非依存。ApiRunMachineFanoutMultiplexerTests が
/// 直接叩く)。runStarted/runFinished は集計して捨てる。workersReady は**子ごとに届くたび**、
/// それまでに判明している全ワーカー(子 index 順の累積)で合成して出し直す —— 拡張側の
/// レーン構成は全置換だが同一 id のログは維持されるため、再送は増分の追加として映る
/// (vscode-fleetest/src/runLaneModel.ts applyWorkers と対)。他のイベントはバッファせず
/// 即時中継する(貯めると複数マシン実行の進行表示が最後に一括更新になる。2026-08-18)。
/// 子が担当シナリオを残して終了したら、そのシナリオを failed の合成イベントで報告する
/// (沈黙のまま「走っていない」を作らない)。
struct MachineFanoutMultiplexer {
    private let groupMachines: [String?]
    /// 子 index → 担当シナリオ ID(合成 failed の対象を知るため)
    private let assignedScenarioIDs: [[String]]
    private var workersByIndex: [[ApiWorkerInfo]]
    private var finishedByIndex: [Set<String>]
    private(set) var totalPassed = 0
    private(set) var totalFailed = 0

    init(groupMachines: [String?], assignedScenarioIDs: [[String]] = []) {
        self.groupMachines = groupMachines
        self.assignedScenarioIDs = assignedScenarioIDs.isEmpty
            ? Array(repeating: [], count: groupMachines.count)
            : assignedScenarioIDs
        self.workersByIndex = Array(repeating: [], count: groupMachines.count)
        self.finishedByIndex = Array(repeating: [], count: groupMachines.count)
    }

    /// 子(childIndex)からの1行。バッファせず、relay してよい行をそのまま返す
    mutating func ingest(childIndex: Int, line: String) -> [String] {
        switch Self.classify(line, host: groupMachines[childIndex]) {
        case .runStarted:
            return []
        case .runFinished(let passed, let failed):
            totalPassed += passed
            totalFailed += failed
            return []
        case .workersReady(let workers):
            workersByIndex[childIndex] = workers
            let merged = groupMachines.indices.flatMap { workersByIndex[$0] }
            return [Self.encode(ApiWorkersReadyEvent(workers: merged))]
        case .other(let rewritten, let finishedScenario):
            if let scenario = finishedScenario { finishedByIndex[childIndex].insert(scenario) }
            return [rewritten]
        }
    }

    /// 子プロセスの終了。担当していたが scenarioFinished が来ないまま終わったシナリオを
    /// failed として合成する(正常に全部完了していれば空配列)
    mutating func childExited(_ index: Int, exitCode: Int32) -> [String] {
        let unfinished = assignedScenarioIDs[index].filter { !finishedByIndex[index].contains($0) }
        guard !unfinished.isEmpty else { return [] }
        totalFailed += unfinished.count
        let machineLabel = DeviceMachineGrouping.display(groupMachines[index])
        var log = ScenarioEvent(kind: "log")
        log.message = "[\(machineLabel)] sub-run exited (status \(exitCode)) — marking "
            + "\(unfinished.count) unfinished scenario(s) as failed"
        var lines = [log.encodedLine()]
        for scenario in unfinished {
            var step = ScenarioEvent(kind: "step")
            step.scenario = scenario
            step.status = "failed"
            step.description = "the sub-run on \(machineLabel) exited (status \(exitCode)) before this "
                + "scenario finished — see the fleetest OUTPUT panel for the dispatch error"
            lines.append(step.encodedLine())

            var finished = ScenarioEvent(kind: "scenarioFinished")
            finished.scenario = scenario
            finished.passed = false
            lines.append(finished.encodedLine())
        }
        return lines
    }

    private enum ClassifiedLine {
        case runStarted
        case runFinished(passed: Int, failed: Int)
        case workersReady([ApiWorkerInfo])
        /// finishedScenario: kind == scenarioFinished のときだけシナリオ ID(childExited の
        /// 未完了判定に使う)
        case other(String, finishedScenario: String?)
    }

    /// **worker フィールドの書き換えは JSON を構造として読み書きする**(文字列置換にすると、
    /// worker のラベルにエンコーダごと違う slash エスケープ規則(ScenarioEvent は
    /// withoutEscapingSlashes・ApiScenarioRequeuedEvent は既定)が混在し、パターンを外して
    /// 書き換え漏れになる)。worker を持たない・kind が未知の行はそのまま素通しする
    /// (壊れた形で再構築しない = 安全側に倒す)
    private static func classify(_ line: String, host: String?) -> ClassifiedLine {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["kind"] as? String else {
            return .other(line, finishedScenario: nil)
        }
        switch kind {
        case "runStarted":
            return .runStarted
        case "runFinished":
            return .runFinished(passed: obj["passed"] as? Int ?? 0, failed: obj["failed"] as? Int ?? 0)
        case "workersReady":
            let raw = obj["workers"] as? [[String: Any]] ?? []
            let workers = raw.compactMap { entry -> ApiWorkerInfo? in
                guard let name = entry["name"] as? String,
                      let platform = entry["platform"] as? String else { return nil }
                let detail = entry["detail"] as? String ?? ""
                return ApiWorkerInfo(
                    id: DeviceMachineGrouping.workerID(platform: platform, machine: host, name: name),
                    name: name, platform: platform, detail: detail, machine: host)
            }
            return .workersReady(workers)
        default:
            let finishedScenario = kind == "scenarioFinished" ? obj["scenario"] as? String : nil
            guard let worker = obj["worker"] as? String,
                  let colon = worker.firstIndex(of: ":") else {
                return .other(line, finishedScenario: finishedScenario)
            }
            let platform = String(worker[..<colon])
            let name = String(worker[worker.index(after: colon)...])
            let rehosted = DeviceMachineGrouping.workerID(platform: platform, machine: host, name: name)
            // 手元(host == nil)は常に無変化 —— 既存の id を1バイトも変えない契約をここで満たす
            guard rehosted != worker else { return .other(line, finishedScenario: finishedScenario) }
            var mutated = obj
            mutated["worker"] = rehosted
            guard let out = try? JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys]),
                  let text = String(data: out, encoding: .utf8) else {
                return .other(line, finishedScenario: finishedScenario)
            }
            return .other(text, finishedScenario: finishedScenario)
        }
    }

    private static func encode(_ event: ApiWorkersReadyEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event), let text = String(data: data, encoding: .utf8) else {
            return #"{"kind":"workersReady","workers":[]}"#
        }
        return text
    }
}
