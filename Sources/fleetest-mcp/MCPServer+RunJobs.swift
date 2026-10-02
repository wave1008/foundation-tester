// MCPServer+RunJobs.swift
// ft_start_run / ft_run_status / ft_stop_run: 本物の `fleetest run` をバックグラウンドで起こし、状態を引く。
//
// **start は即座に返し、status は引いて読む**(MCPServer は1リクエストずつ処理するので、長い待ちは
// 他の ft_* を全部止める。Codex は MCP の呼び出しを約60秒で切る)。
// **`fleetest api run` ではなく `fleetest run` を起こす**: --failed / --broadcast / --folder は後者にしか無い。
// **`swift run` 経由**: MCP のランチャーが作るのは fleetest-mcp だけで、隣の fleetest は古いことがある。
// **子の出力はパイプで読まない**(ログファイルへ直接)—— readDataToEndOfFile / availableData の走査テストの対象外にする。
// **止めるのは SIGTERM だけ**(時限の SIGKILL を送らない。fleetest run が自前の後始末を持つ。process-lifecycle の規律)

import Foundation
import FTBridgeClient
import FTCore

/// 起こした run 1本。`process` を握っているのは回収(terminationHandler)のため
struct MCPRunJob {
    let pid: Int32
    let process: Process
    let arguments: [String]
    let logURL: URL
    let startedAt: Date
    let project: String
    let profile: String
    let packageRoot: URL
    let resultsDir: URL
}

enum MCPRunJobState: Equatable {
    case running
    case exited(Int32)
    case signaled(Int32)
}

/// この MCP プロセスが起こした run の台帳。**終了の記録は terminationHandler(任意のスレッド)から来る**
/// のでロックで守る。pid を持たない(= 起こしていない)run は引けない = 他人の run は止めも読みもしない
final class MCPRunJobRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [MCPRunJob] = []
    private var exits: [Int32: (state: MCPRunJobState, at: Date)] = [:]

    func add(_ job: MCPRunJob) {
        lock.lock(); defer { lock.unlock() }
        jobs.append(job)
    }

    /// terminationHandler から。**add より先に呼ばれうる**(起動直後に落ちた子)ので pid だけを鍵にする
    func recordExit(pid: Int32, reason: Process.TerminationReason, status: Int32) {
        lock.lock(); defer { lock.unlock() }
        exits[pid] = (reason == .uncaughtSignal ? .signaled(status) : .exited(status), Date())
    }

    func state(of pid: Int32) -> (state: MCPRunJobState, endedAt: Date?) {
        lock.lock(); defer { lock.unlock() }
        guard let exit = exits[pid] else { return (.running, nil) }
        return (exit.state, exit.at)
    }

    func job(pid: Int32) -> MCPRunJob? {
        lock.lock(); defer { lock.unlock() }
        return jobs.first { $0.pid == pid }
    }

    /// 引数省略時の宛先 = 最後に起こした run
    var latest: MCPRunJob? {
        lock.lock(); defer { lock.unlock() }
        return jobs.last
    }

    var runningJob: MCPRunJob? {
        lock.lock(); defer { lock.unlock() }
        return jobs.last { exits[$0.pid] == nil }
    }

    var knownPIDs: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return jobs.map(\.pid)
    }
}

/// status の表示に要る材料(純粋関数 `statusText` の入力)
struct MCPRunStatusInput {
    var pid: Int32
    var state: MCPRunJobState
    var elapsedSeconds: Int
    var project: String
    var profile: String
    var logPath: String
    var logTail: [String]
    var progress: RunProgressRecord?
    var meta: RunMetaRecord?
    var runDirPath: String?
    var failedScenarios: [MCPFailedScenario]
}

struct MCPFailedScenario: Equatable {
    let id: String
    let platform: String
    let reason: String?
    let reportPath: String?
}

enum MCPRunJobs {

    /// `/usr/bin/env` へ渡す引数。**`--scenario` / `--folder` は1回のフラグに値を並べる**
    /// (`FleetRunner.buildArgs` と同じ形。両方 upToNextOption)
    static func arguments(profile: String, project: String?, runner: String?, scenarios: [String],
                          folders: [String], failed: Bool, broadcast: Bool) -> [String] {
        var args = ["swift", "run", "fleetest", "run"]
        if let project { args += ["--project", project] }
        args += ["--profile", profile]
        if let runner { args += ["--runner", runner] }
        if !scenarios.isEmpty { args += ["--scenario"] + scenarios }
        if !folders.isEmpty { args += ["--folder"] + folders }
        if failed { args.append("--failed") }
        if broadcast { args.append("--broadcast") }
        return args
    }

    /// `runner` は `local` と登録簿の機械名だけを通す。**生の宛先(user@host)は断る** —— CLI の `--runner` は
    /// 受け付けるが、MCP は承認なしで呼ばれうるので、登録していない機械へシナリオ・プロファイルを送る
    /// 持ち出し口になる(どこへ送ってよいかは利用者が `fleetest remote machines add` で決める)
    static func runnerRefusal(_ runner: String, registered: [String]) -> String? {
        let name = runner.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "local" || registered.contains(name) { return nil }
        let known = registered.isEmpty ? "none is registered" : "registered: \(registered.sorted().joined(separator: ", "))"
        return "runner must be \"local\" or a machine registered with `fleetest remote machines add` (\(known));"
            + " raw hosts are not accepted here, so tests are only sent where the user registered a machine"
    }

    static func commandLine(_ arguments: [String]) -> String {
        (["env"] + arguments).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    /// 子の環境。`FT_PARENT_PID`(MCP が死んだら子が自分で SIGTERM)+ 親が決めた2つの場所を固定する
    /// (`RunCompletionSweep.childEnvironment` と同じ。子に解決し直させると外部パッケージ構成で取り違える)
    static func childEnvironment(packageRoot: URL, toolRoot: URL?,
                                 base: [String: String]? = nil) -> [String: String] {
        var env = ParentDeathWatch.childEnvironment(base: base)
        env["FT_PACKAGE_ROOT"] = packageRoot.path
        if let toolRoot { env["FT_TOOL_ROOT"] = toolRoot.path }
        return env
    }

    // MARK: - run の突き合わせ

    /// ISO8601(小数秒の有無どちらも)。台帳も run.json も秒精度だが、読み違えて落とさない
    static func parseISO(_ text: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// startedAt は秒に切り捨てて書かれるので、起こした時刻との比較にこの幅を持たせる
    /// (起動時刻のほうが記録より最大1秒新しく見える)
    static let startSlackSeconds: TimeInterval = 1

    private static func startedNotBefore(_ startedAt: String, _ spawnedAt: Date) -> Bool {
        guard let started = parseISO(startedAt) else { return false }
        return started >= spawnedAt.addingTimeInterval(-startSlackSeconds)
    }

    /// 実行中の進捗。**pid が一致する控えを最優先**。`swift run` が製品を exec せず子として起こす版では
    /// 台帳の pid は Process の pid と違うので、project + profile が同じで起こした時刻以後に始まった
    /// 最新の控えを採る
    static func matchProgress(_ records: [RunProgressRecord], pid: Int32, project: String,
                              profile: String, spawnedAt: Date) -> RunProgressRecord? {
        if let exact = records.first(where: { $0.pid == pid }) { return exact }
        return records
            .filter { $0.project == project && $0.profile == profile
                && startedNotBefore($0.startedAt, spawnedAt) }
            .max { $0.startedAt < $1.startedAt }
    }

    /// 終わった run の run.json。pid 一致を優先し、無ければ project + profile + 起こした時刻以後の最新。
    /// 機械分担 run(runGroup)は複数ありうるが、最新の1本を採る
    static func matchRunMeta(_ runs: [(meta: RunMetaRecord, dir: URL)], pid: Int32, project: String,
                             profile: String, spawnedAt: Date) -> (meta: RunMetaRecord, dir: URL)? {
        let candidates = runs.filter {
            $0.meta.project == project && $0.meta.profile == profile
                && startedNotBefore($0.meta.startedAt, spawnedAt)
        }
        let byPID = candidates.filter { $0.meta.pid == Int(pid) }
        return (byPID.isEmpty ? candidates : byPID).max { $0.meta.startedAt < $1.meta.startedAt }
    }

    /// runID の先頭(`yyyyMMdd-HHmmss` UTC。辞書順 = 時系列)での下限。これ未満の run ディレクトリは読まない
    /// (月に数千 run ある結果ディレクトリを status のたびに全部デコードしない)
    static func runIDFloor(spawnedAt: Date) -> String {
        utcFormatter("yyyyMMdd-HHmmss").string(from: spawnedAt.addingTimeInterval(-startSlackSeconds))
    }

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    /// 起こした時刻以後の run ディレクトリ(run.json が読めたものだけ)。月ディレクトリは起こした月と今月
    static func candidateRuns(resultsDir: URL, spawnedAt: Date,
                              now: Date = Date()) -> [(meta: RunMetaRecord, dir: URL)] {
        let runsDir = resultsDir.appendingPathComponent("runs")
        let floor = runIDFloor(spawnedAt: spawnedAt)
        let monthFormatter = utcFormatter("yyyy-MM")
        var months: [String] = []
        for date in [spawnedAt, now] {
            let month = monthFormatter.string(from: date)
            if !months.contains(month) { months.append(month) }
        }
        var found: [(meta: RunMetaRecord, dir: URL)] = []
        for month in months {
            let monthDir = runsDir.appendingPathComponent(month)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: monthDir.path) else { continue }
            for name in names where name >= floor {
                let dir = monthDir.appendingPathComponent(name)
                if let meta = RunResultsStore.meta(runDir: dir) { found.append((meta, dir)) }
            }
        }
        return found
    }

    // MARK: - 失敗シナリオ

    /// 落ちたシナリオ(対象外の合成レコードは数えない = run の失敗数と同じ)。reportPath は
    /// リポジトリルート相対で記録されているので絶対パスへ直す
    static func failedScenarios(records: [ScenarioRunRecord], packageRoot: URL) -> [MCPFailedScenario] {
        records.filter { !$0.passed && $0.skipKind != .notApplicable }.map { record in
            let step = record.failedSteps?.first
            let reason = step.map { $0.detail ?? $0.description } ?? record.errorLogs?.last
            let report = record.reportPath.map { path in
                path.hasPrefix("/") ? path : packageRoot.appendingPathComponent(path).path
            }
            return MCPFailedScenario(id: record.scenarioID, platform: record.platform,
                                     reason: reason.map { truncated($0, 160) }, reportPath: report)
        }
    }

    private static func truncated(_ text: String, _ limit: Int) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
    }

    /// 失敗の一覧に出す行数の上限(束ねた後の行)。多いと応答が膨らむ(残りは results ディレクトリにある)
    static let failedListLimit = 20
    /// ログ末尾の行数
    static let logTailLines = 30

    /// ログの末尾。**末尾 64KB だけ読む**(ビルドの出力で長くなる。1行が極端に長い場合も有限)
    static func logTail(url: URL, lines: Int = logTailLines) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).map(String.init))
    }

    /// 同じ (シナリオ, platform, 理由) の行を1つに束ねたもの。全デバイス実行(broadcast)の中断前の
    /// 「始まらなかった」が台数ぶん同じ行で並ぶのを防ぐ。初出順を保つ
    struct FailureGroup: Equatable {
        let id: String
        let platform: String
        let reason: String?
        var count: Int
        var reportPaths: [String]
    }

    static func groupedFailures(_ failures: [MCPFailedScenario]) -> [FailureGroup] {
        var groups: [FailureGroup] = []
        for failure in failures {
            if let index = groups.firstIndex(where: {
                $0.id == failure.id && $0.platform == failure.platform && $0.reason == failure.reason
            }) {
                groups[index].count += 1
                if let report = failure.reportPath, !groups[index].reportPaths.contains(report) {
                    groups[index].reportPaths.append(report)
                }
            } else {
                groups.append(FailureGroup(id: failure.id, platform: failure.platform, reason: failure.reason,
                                           count: 1, reportPaths: failure.reportPath.map { [$0] } ?? []))
            }
        }
        return groups
    }

    /// 束ねた行に出すレポートパスの上限(超えたら先頭1本 + 残りの本数)。応答を膨らませない
    static let failureRowReportLimit = 3

    static func failureRow(_ group: FailureGroup) -> String {
        var row = "- \(group.id) (\(group.platform))"
        if group.count > 1 { row += " on \(group.count) devices" }
        if let reason = group.reason { row += ": \(reason)" }
        if group.reportPaths.count > failureRowReportLimit {
            row += " — report: \(group.reportPaths[0]) (+\(group.reportPaths.count - 1) more)"
        } else if group.reportPaths.count > 1 {
            row += " — reports: \(group.reportPaths.joined(separator: ", "))"
        } else if let report = group.reportPaths.first {
            row += " — report: \(report)"
        }
        return row
    }

    // MARK: - 文面

    static func durationText(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    static func statusText(_ input: MCPRunStatusInput) -> String {
        var lines: [String] = []
        let elapsed = durationText(input.elapsedSeconds)
        switch input.state {
        case .running:
            lines.append("Run pid \(input.pid): running (elapsed \(elapsed)) — profile \(input.profile), project \(input.project)")
            if let progress = input.progress {
                lines.append("Progress: \(progress.done)/\(progress.total) done, \(progress.failed) failed,"
                    + " phase: \(progress.phase)")
            } else {
                lines.append("Progress: not available yet (building or starting up) — poll again")
            }
        case .exited(let code):
            lines.append("Run pid \(input.pid): finished with exit code \(code) (elapsed \(elapsed)) — profile \(input.profile), project \(input.project)")
        case .signaled(let signal):
            lines.append("Run pid \(input.pid): stopped by signal \(signal) (elapsed \(elapsed)) — profile \(input.profile), project \(input.project)")
        }
        if input.state != .running {
            if let meta = input.meta {
                var summary = "Run \(meta.runID): \(meta.passed ?? 0) passed / \(meta.failed ?? 0) failed"
                    + " / \(meta.total ?? 0) total"
                if meta.interrupted == true { summary += " — interrupted" }
                lines.append(summary)
                if let reason = meta.abortReason { lines.append("Aborted: \(reason)") }
                if let path = input.runDirPath { lines.append("Results: \(path)") }
            } else {
                lines.append("No run record was found (the run may have ended before recording — read the log)")
            }
            let groups = MCPRunJobs.groupedFailures(input.failedScenarios)
            if !groups.isEmpty {
                lines.append("Failed scenarios:")
                for group in groups.prefix(failedListLimit) { lines.append(failureRow(group)) }
                let more = groups.count - failedListLimit
                if more > 0 { lines.append("(+\(more) more — see the results directory)") }
            }
        }
        lines.append("Log: \(input.logPath)")
        if !input.logTail.isEmpty {
            lines.append("--- last \(input.logTail.count) log line(s) ---")
            lines += input.logTail
        }
        return lines.joined(separator: "\n")
    }
}

extension MCPServer {

    /// 文字列配列の引数。**型違い・空要素は名指しで断る**(配列型は入口の型検査の対象外)
    static func stringListArgument(_ args: [String: Any], _ key: String) throws -> [String] {
        guard let raw = args[key] else { return [] }
        guard let items = raw as? [Any] else {
            throw MCPError("\(key) must be an array of strings (got \(describeArgumentValue(raw)))")
        }
        return try items.enumerated().map { index, item in
            guard let value = item as? String else {
                throw MCPError("\(key)[\(index)] must be a string (got \(describeArgumentValue(item)))")
            }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError("\(key)[\(index)] must not be empty")
            }
            return value
        }
    }

    func startRun(_ args: [String: Any]) throws -> [[String: Any]] {
        let profile = try Self.requiredStringArgument(args, "profile")
        let scenarios = try Self.stringListArgument(args, "scenario")
        let folders = try Self.stringListArgument(args, "folder")
        let runner = try Self.stringArgument(args, "runner")
        if let runner, let refusal = MCPRunJobs.runnerRefusal(
            runner, registered: LocalConfig.load().remoteHosts?.map(\.machine) ?? []) {
            throw MCPError(refusal)
        }
        let failed = try Self.flagArgument(args, "failed")
        let broadcast = try Self.flagArgument(args, "broadcast")
        if let running = runJobs.runningJob {
            throw MCPError("a run started by this server is still running (pid \(running.pid), profile"
                + " \(running.profile)) — poll it with ft_run_status (pid: \(running.pid)) or stop it with"
                + " ft_stop_run (pid: \(running.pid)) before starting another")
        }
        guard let packageRoot = ScenarioHost.packageRoot() else {
            throw MCPError("Package.swift not found (run this inside the repository)")
        }
        let project = try ScenarioHost.project(named: args["project"] as? String)
        let arguments = MCPRunJobs.arguments(
            profile: profile, project: project.name, runner: runner, scenarios: scenarios, folders: folders,
            failed: failed, broadcast: broadcast)

        let logDir = packageRoot.appendingPathComponent(".fleetest").appendingPathComponent("mcp-runs")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let logURL = logDir.appendingPathComponent(
            "\(stamp.string(from: Date()))-\(UUID().uuidString.prefix(8)).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil),
              let logHandle = try? FileHandle(forWritingTo: logURL) else {
            throw MCPError("cannot create the run log at \(logURL.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = packageRoot
        process.environment = MCPRunJobs.childEnvironment(
            packageRoot: packageRoot, toolRoot: try? RepoRoot.find())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        let registry = runJobs
        process.terminationHandler = { finished in
            registry.recordExit(pid: finished.processIdentifier, reason: finished.terminationReason,
                                status: finished.terminationStatus)
        }
        let spawnedAt = Date()
        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw MCPError("cannot start the run: \(error.localizedDescription)")
        }
        // 子が継いだ書き込み口は子が持つ。こちらの口は閉じる(ログの追記は子の fd で続く)
        try? logHandle.close()
        let job = MCPRunJob(
            pid: process.processIdentifier, process: process, arguments: arguments, logURL: logURL,
            startedAt: spawnedAt, project: project.name, profile: profile, packageRoot: packageRoot,
            resultsDir: RunResultsStore.resultsDir(projectRoot: project.rootURL))
        runJobs.add(job)
        return text("Started a run in the background (pid \(job.pid)).\n"
            + "Command: \(MCPRunJobs.commandLine(arguments))\n"
            + "Log: \(logURL.path)\n"
            + "Poll ft_run_status (pid: \(job.pid)); stop it with ft_stop_run (pid: \(job.pid)).")
    }

    /// 省略時は最後に起こした run。**この server が起こしていない pid は断る**(他人の run を読まない・止めない)
    private func resolveRunJob(_ args: [String: Any]) throws -> MCPRunJob {
        if let pid = try Self.intArgument(args, "pid") {
            guard let job = runJobs.job(pid: Int32(pid)) else {
                let known = runJobs.knownPIDs
                throw MCPError("pid \(pid) is not a run started by this server"
                    + (known.isEmpty ? " (none has been started)"
                        : " (started here: \(known.map(String.init).joined(separator: ", ")))"))
            }
            return job
        }
        guard let job = runJobs.latest else {
            throw MCPError("no run has been started by this server — start one with ft_start_run")
        }
        return job
    }

    func runStatus(_ args: [String: Any]) throws -> [[String: Any]] {
        let job = try resolveRunJob(args)
        let (state, endedAt) = runJobs.state(of: job.pid)
        var input = MCPRunStatusInput(
            pid: job.pid, state: state,
            elapsedSeconds: Int((endedAt ?? Date()).timeIntervalSince(job.startedAt)),
            project: job.project, profile: job.profile, logPath: job.logURL.path,
            logTail: MCPRunJobs.logTail(url: job.logURL), progress: nil, meta: nil,
            runDirPath: nil, failedScenarios: [])
        if state == .running {
            let records = RunProgressLedger.readAll(
                directory: RunProgressLedger.directory(), startTime: ProcessLiveness.startTime)
            input.progress = MCPRunJobs.matchProgress(
                records, pid: job.pid, project: job.project, profile: job.profile,
                spawnedAt: job.startedAt)
        } else if let found = MCPRunJobs.matchRunMeta(
            MCPRunJobs.candidateRuns(resultsDir: job.resultsDir, spawnedAt: job.startedAt),
            pid: job.pid, project: job.project, profile: job.profile, spawnedAt: job.startedAt) {
            input.meta = found.meta
            input.runDirPath = found.dir.path
            input.failedScenarios = MCPRunJobs.failedScenarios(
                records: RunResultsStore.records(runDir: found.dir), packageRoot: job.packageRoot)
        }
        return text(MCPRunJobs.statusText(input))
    }

    func stopRun(_ args: [String: Any]) throws -> [[String: Any]] {
        let job = try resolveRunJob(args)
        guard runJobs.state(of: job.pid).state == .running else {
            return text("Run pid \(job.pid) has already finished — read the result with ft_run_status (pid: \(job.pid)).")
        }
        // SIGTERM だけ。fleetest run が自前の後始末(終了スクリプト・ロック解放・録画の確定)を走らせる。
        // 刺さっても時限の SIGKILL は送らない(人が止める)
        kill(job.pid, SIGTERM)
        return text("Sent SIGTERM to run pid \(job.pid). It tears down on its own (this can take a while) —"
            + " poll ft_run_status (pid: \(job.pid)) until it reports finished.")
    }

    /// 省略 = false の真偽値引数(型違いは `booleanArgumentTypeError`)
    private static func flagArgument(_ args: [String: Any], _ key: String) throws -> Bool {
        guard let raw = args[key] else { return false }
        guard isJSONBoolean(raw), let value = raw as? Bool else {
            throw MCPError(booleanArgumentTypeError(key: key, raw: raw))
        }
        return value
    }
}
