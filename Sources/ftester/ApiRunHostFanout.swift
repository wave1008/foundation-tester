// ApiRunHostFanout.swift
// `ftester api run --profile <p>` で p のデバイスが複数の機械にまたがるときの実行
// (docs/remote-runner.md §13)。DeviceHostRunner(`ftester run` の同じ状況)と同じ割り当て
// (build→list→resolve→assign)を再利用し、ホストごとに `ftester api run --host <label> …` を
// 子プロセスとして並行に起動、NDJSON を1本の stdout ストリームへ多重化する。
//
// 拡張(vscode-ftester/src/model.ts)は「1本の NDJSON = runStarted → workersReady →
// (各種イベント) → runFinished」という契約しか知らない。子1つにつき1本ずつ来る同じ形の
// ストリームを、runStarted/runFinished は集計してこちらが1回だけ出し、workersReady は
// 全子ぶん揃うまで待って合成し、それ以外は worker フィールドをホスト付き id
// (FTCore.DeviceHostGrouping.workerID)へ書き換えて素通しする。

import ArgumentParser
import FTCore
import Foundation

enum ApiRunHostFanout {

    /// 子プロセスへ素通しするオプション。skipBuild/folders は無い —— ビルドは常にここで1回だけ
    /// 行う(DeviceHostRunner.run と同じ理由。シナリオ一覧が割り当てに要る)。--report-dir は
    /// 意図的に含めない: リモートホストの子は `dispatchToRemoteHost` が --report-dir を
    /// 常に拒否するため(RemoteDispatchFlagPolicy.rejected)、一部のホストにだけ効く/効かないが
    /// 混在する形になる。CLI 側の多機械ディスパッチ(DeviceHostRunner/FleetRunner)も同じ理由で
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
        project: TestProject, profileName: String, groups: [DeviceHostRunner.Group],
        scenarios: [String], options: Options
    ) async throws -> Int32 {
        let hostList = groups.map { "\($0.hostLabel)(\($0.deviceNames.count))" }.joined(separator: " + ")
        logStderr("==> profile \"\(profileName)\" spans \(groups.count) machines: \(hostList)"
            + " — building \(project.name) locally to split the scenarios")

        // 割り当てを決めるにはシナリオ一覧が要る(DeviceHostRunner.run と同じ理由。ここで1回だけ
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

        let buckets = try DeviceHostRunner.assign(
            project: project, groups: groups, selected: selected,
            lptHistoryRuns: options.lptHistoryRuns)
        let active = groups.indices.compactMap { index -> (index: Int, group: DeviceHostRunner.Group, ids: [String])? in
            let ids = buckets[index].scenarioIDs
            return ids.isEmpty ? nil : (index, groups[index], ids)
        }
        // FleetSplit.partition は各エントリの platform 集合に合う本数だけ割り当てる。全滅は
        // 「このプロファイルのどのホストもこのシナリオ集合の platform を持たない」という設定ミスで、
        // NDJSON を1行も出さず即座に落とすほうが「全部走った」という誤読より安全
        guard !active.isEmpty else {
            throw ValidationError(
                "profile \"\(profileName)\": every machine was assigned 0 scenarios"
                + " (\(hostList)) — check that some machine's devices match the scenarios' platform")
        }
        for (_, group, ids) in active {
            logStderr("    \(group.hostLabel): \(ids.count) scenario(s) on \(group.deviceNames.count) device(s)")
        }

        writeLine(encode(ApiRunStartedEvent(total: selected.count)))
        let dispatchStart = Date()

        let binary = FleetRunner.selfBinaryPath()
        let (stream, continuation) = AsyncStream<ChildEvent>.makeStream()
        let groupHosts = active.map { $0.group.host }

        async let multiplexed = consume(stream: stream, groupHosts: groupHosts)

        // 拡張のキャンセル(SIGTERM/SIGINT)・stdin EOF のどちらでも全子へ SIGTERM を送る。
        // 子(単発の `ftester api run --host <label>`)は自分ではシグナルを捕まえないので既定の
        // 即時終了になり、リモート子はその内部の ssh(-tt 付き)が親の死で SIGHUP を孫プロセスへ
        // 伝える(RemoteRunDispatcher.sshRunBase の宣言と同じ機構)。単発 `api run --host` は
        // 自分自身が拡張の直接の子なので OS がこの経路で保護するが、ここは**この fanout が
        // 増やした孫プロセス**を対象にする(既存の保護の外側)
        let registry = ChildProcessRegistry()
        let cancelSources = installCancellation(registry: registry)
        defer { for source in cancelSources { source.cancel() } }

        let outcomes = await withTaskGroup(of: (Int, FleetEntryOutcome).self) { taskGroup in
            for (position, entry) in active.enumerated() {
                let (_, group, ids) = entry
                taskGroup.addTask {
                    let args = buildArgs(
                        project: project.name, profileName: profileName, group: group,
                        scenarioIDs: ids, options: options)
                    let start = Date()
                    let exitCode = await runChild(
                        index: position, binary: binary, args: args, hostLabel: group.hostLabel,
                        continuation: continuation, registry: registry)
                    return (position, FleetEntryOutcome(
                        host: group.hostLabel, profile: profileName, exitCode: exitCode,
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

    private static func buildArgs(
        project: String, profileName: String, group: DeviceHostRunner.Group,
        scenarioIDs: [String], options: Options
    ) -> [String] {
        let hostLabel = group.hostLabel
        var args = ["api", "run", "--project", project, "--profile", profileName]
        // **常に --host を渡す**(FleetRunner.buildArgs と同じ理由: 省略すると子が自分でマシン
        // プロファイルの host を再解決してしまう。"local" は MachineHostDispatch.resolve が
        // 明示指定として止める)
        args += ["--host", hostLabel]
        // **--skip-build はローカル子だけ**(dispatchToRemoteHost が .explicitHost origin では
        // "--skip-build is not supported with --host" で拒否する。RemoteDispatchFlagPolicy.skipBuild
        // の宣言参照。リモートは自前でビルドするので、渡す必要も無い)
        if hostLabel == DeviceHostGrouping.localDisplayName {
            args += ["--skip-build"]
        } else {
            if let remoteDir = options.remoteDir { args += ["--remote-dir", remoteDir] }
            if let remoteTimeout = options.remoteTimeout { args += ["--remote-timeout", String(remoteTimeout)] }
            if options.remoteArtifacts != "collect" { args += ["--remote-artifacts", options.remoteArtifacts] }
        }
        // **ホストも渡す**(一意なのは (host, name)。ApiRunCommand.deviceHost の宣言参照)
        args += ["--device"] + group.deviceNames
        args += ["--device-host", hostLabel]
        args += ["--scenario"] + scenarioIDs
        if options.heal { args += ["--heal"] }
        if options.noLPT { args += ["--no-lpt"] }
        if let lptHistoryRuns = options.lptHistoryRuns { args += ["--lpt-history-runs", String(lptHistoryRuns)] }
        if options.performanceMode { args += ["--performance"] }
        if let defaultTimeout = options.defaultTimeout { args += ["--default-timeout", String(defaultTimeout)] }
        if let scenarioTimeout = options.scenarioTimeout { args += ["--scenario-timeout", String(scenarioTimeout)] }
        return args
    }

    // MARK: - 子プロセス

    private enum ChildEvent {
        case line(index: Int, text: String)
        case exited(index: Int)
    }

    /// 子1体ぶん。stdout(NDJSON)は行単位で continuation へ、stderr(診断)はホスト名を前置して
    /// そのまま親の stderr へ流す(stdout は NDJSON 専用の契約なので混ぜない)
    private static func runChild(
        index: Int, binary: String, args: [String], hostLabel: String,
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
            logStderr("[\(hostLabel)] error: failed to launch subprocess: \(error.localizedDescription)")
            continuation.yield(.exited(index: index))
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
                let chunk = stdoutHandle.readData(ofLength: 65536)
                if chunk.isEmpty { break }
                for line in stdoutSplitter.feed(chunk) { continuation.yield(.line(index: index, text: line)) }
            }
            stdoutDone.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = stderrHandle.readData(ofLength: 65536)
                if chunk.isEmpty { break }
                for line in stderrSplitter.feed(chunk) { logStderr("[\(hostLabel)] \(line)") }
            }
            stderrDone.signal()
        }

        for await _ in exitStream {}
        stdoutDone.wait()
        stderrDone.wait()
        if let remaining = stdoutSplitter.flush() { continuation.yield(.line(index: index, text: remaining)) }
        if let remaining = stderrSplitter.flush() { logStderr("[\(hostLabel)] \(remaining)") }
        continuation.yield(.exited(index: index))
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
    }

    /// SIGTERM・SIGINT で registry.terminateAll() を呼ぶ(ApiLiveServe/ApiMonitorCommand と
    /// 同じ規律: DispatchSourceSignal を使うには先に SIG_IGN が要る)。拡張のキャンセルは
    /// SIGTERM(vscode-ftester/src/cli.ts の proc.kill)なのでこれで届く。
    /// 戻り値は子の待機が終わるまで保持すること(解放されるとハンドラが外れる)。
    ///
    /// **stdin の EOF を打ち切りの合図に使ってはいけない** —— `api run` は --debug 以外
    /// stdin を読まず、拡張は stdio[0] を "ignore"(= /dev/null)で起動する。EOF を見ると
    /// 起動と同時に全子プロセスを殺すことになる(実際にそうなり、拡張からの実行が
    /// 開始直後に exit=15 で全滅した)
    private static func installCancellation(registry: ChildProcessRegistry) -> [DispatchSourceSignal] {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let queue = DispatchQueue(label: "ftester-api-run-fanout-signal")
        return [SIGTERM, SIGINT].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { registry.terminateAll() }
            source.resume()
            return source
        }
    }

    // MARK: - 多重化(I/O 側。純粋な状態機械は HostFanoutMultiplexer)

    private static func consume(
        stream: AsyncStream<ChildEvent>, groupHosts: [String?]
    ) async -> (passed: Int, failed: Int) {
        var multiplexer = HostFanoutMultiplexer(groupHosts: groupHosts)
        for await event in stream {
            switch event {
            case .line(let index, let text):
                for line in multiplexer.ingest(childIndex: index, line: text) { writeLine(line) }
            case .exited(let index):
                for line in multiplexer.childExited(index) { writeLine(line) }
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

/// 子の NDJSON を1本へ多重化する状態機械(純粋・プロセス非依存。ApiRunHostFanoutMultiplexerTests が
/// 直接叩く)。runStarted/runFinished は集計して捨て、workersReady は groupHosts.count 個ぶん
/// (workersReady を出した子・出さずに終了した子のどちらも1個と数える)揃うまで待って1回だけ
/// 合成し、揃うまでの他イベントは到着順のまま貯めて合成の直後に流す。
struct HostFanoutMultiplexer {
    private let groupHosts: [String?]
    private var settled: [Bool]
    private var settledCount = 0
    private var readyEmitted = false
    private var workersByIndex: [[ApiWorkerInfo]]
    private var buffer: [String] = []
    private(set) var totalPassed = 0
    private(set) var totalFailed = 0

    init(groupHosts: [String?]) {
        self.groupHosts = groupHosts
        self.settled = Array(repeating: false, count: groupHosts.count)
        self.workersByIndex = Array(repeating: [], count: groupHosts.count)
    }

    /// 子(childIndex)からの1行。即座に relay してよい行を返す(まだ揃っていなければ空配列を
    /// 返し、行は内部バッファへ積む)
    mutating func ingest(childIndex: Int, line: String) -> [String] {
        switch Self.classify(line, host: groupHosts[childIndex]) {
        case .runStarted:
            return []
        case .runFinished(let passed, let failed):
            totalPassed += passed
            totalFailed += failed
            return settle(childIndex)
        case .workersReady(let workers):
            workersByIndex[childIndex] = workers
            return settle(childIndex)
        case .other(let rewritten):
            guard readyEmitted else {
                buffer.append(rewritten)
                return []
            }
            return [rewritten]
        }
    }

    /// 子プロセスの終了(workersReady を出さずに終わった場合の安全弁。待ち続けない)
    mutating func childExited(_ index: Int) -> [String] {
        settle(index)
    }

    private mutating func settle(_ index: Int) -> [String] {
        if !settled[index] {
            settled[index] = true
            settledCount += 1
        }
        guard !readyEmitted, settledCount == groupHosts.count else { return [] }
        readyEmitted = true
        let workers = groupHosts.indices.flatMap { workersByIndex[$0] }
        let readyLine = Self.encode(ApiWorkersReadyEvent(workers: workers))
        let flushed = buffer
        buffer.removeAll()
        return [readyLine] + flushed
    }

    private enum ClassifiedLine {
        case runStarted
        case runFinished(passed: Int, failed: Int)
        case workersReady([ApiWorkerInfo])
        case other(String)
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
            return .other(line)
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
                    id: DeviceHostGrouping.workerID(platform: platform, host: host, name: name),
                    name: name, platform: platform, detail: detail, machineHost: host)
            }
            return .workersReady(workers)
        default:
            guard let worker = obj["worker"] as? String,
                  let colon = worker.firstIndex(of: ":") else { return .other(line) }
            let platform = String(worker[..<colon])
            let name = String(worker[worker.index(after: colon)...])
            let rehosted = DeviceHostGrouping.workerID(platform: platform, host: host, name: name)
            // 手元(host == nil)は常に無変化 —— 既存の id を1バイトも変えない契約をここで満たす
            guard rehosted != worker else { return .other(line) }
            var mutated = obj
            mutated["worker"] = rehosted
            guard let out = try? JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys]),
                  let text = String(data: out, encoding: .utf8) else { return .other(line) }
            return .other(text)
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
