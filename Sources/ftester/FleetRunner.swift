// FleetRunner.swift
// `ftester run --fleet <name>`(docs/remote-runner.md §13「フリート実行」)。
// 各エントリを、この ftester バイナリ自身の子プロセスとして並行に起動する
// ("local" → `ftester run --profile <p> …` / それ以外 → `ftester run --host <h> --profile <p> …`)。
// **子プロセス方式にする理由**: ローカル実行の出力は ProfileRunner 等の深い階層から直接
// stdout へ書かれており、プロセス内蔵の hook では行ごとに `[<host>] ` を前置できない
// (リモート側も RemoteRunDispatcher が stdout へ直接書く。同じ理由)。プロセス境界で捕まえれば
// local/remote を同じ仕組みで prefix できる。同一ホストへの二重ディスパッチ防止(dispatch.lock)は
// 子プロセスが `--host` 経由でいつも通る RemoteRunDispatcher.dispatch が担うので、ここでは
// 何もしなくてよい ―― フリート専用のロック処理を重複して持たない。

import ArgumentParser
import FTCore
import Foundation

struct FleetEntryOutcome: Sendable {
    let host: String
    let profile: String
    let exitCode: Int32
    let duration: TimeInterval
}

enum FleetRunner {

    /// 全エントリを並行起動し、1画面の集計を出す。戻り値 = FleetProfile.aggregateExitCode
    static func run(
        project: TestProject, fleetName: String, fleet: FleetProfileDocument,
        scenarios: [String], folders: [String],
        heal: Bool, noHeal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
        fastInput: Bool, enableAnimations: Bool, performanceMode: Bool,
        forceLock: Bool, remoteDir: String?, remoteTimeout: Int?, remoteArtifacts: String,
        quiet: Bool
    ) async throws -> Int32 {
        try preflightFolders(folders, project: project, fleetName: fleetName)

        let binary = selfBinaryPath()
        log("==> fleet \"\(fleetName)\": launching \(fleet.runs.count) entr"
            + "\(fleet.runs.count == 1 ? "y" : "ies") in parallel")

        let outcomes = await withTaskGroup(of: (Int, FleetEntryOutcome).self) { group in
            for (index, entry) in fleet.runs.enumerated() {
                group.addTask {
                    let args = buildArgs(
                        project: project.name, entry: entry, scenarios: scenarios, folders: folders,
                        heal: heal, noHeal: noHeal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
                        fastInput: fastInput, enableAnimations: enableAnimations,
                        performanceMode: performanceMode, forceLock: forceLock,
                        remoteDir: remoteDir, remoteTimeout: remoteTimeout,
                        remoteArtifacts: remoteArtifacts, quiet: quiet)
                    let start = Date()
                    let exitCode = await runEntry(binary: binary, args: args, hostLabel: entry.host)
                    return (index, FleetEntryOutcome(
                        host: entry.host, profile: entry.profile, exitCode: exitCode,
                        duration: Date().timeIntervalSince(start)))
                }
            }
            var collected: [Int: FleetEntryOutcome] = [:]
            for await (index, outcome) in group { collected[index] = outcome }
            return fleet.runs.indices.compactMap { collected[$0] }
        }

        printSummary(fleetName: fleetName, outcomes: outcomes)
        return FleetProfile.aggregateExitCode(outcomes.map(\.exitCode))
    }

    // MARK: - preflight

    /// `--folder` は project 全体で共有(フリート定義に per-entry のシナリオ絞り込みは無い)ので、
    /// 「どのエントリでも要らない」は project 単位で決まる。**シナリオ実体の走査には
    /// ビルド済みランナーが要る**ため、ここで判定できるのは "フォルダ名が実在するか" だけ
    /// (ScenarioFolders.list はディレクトリ一覧なのでビルド不要)。--scenario(Class.method の
    /// ID)の存在確認は各エントリの子プロセス自身の resolve() に委ねる ―— 全滅なら集約 exit code が
    /// 非0になり、結果として「全エントリ0件は中止」に相当する状態になる
    private static func preflightFolders(_ folders: [String], project: TestProject, fleetName: String) throws {
        guard !folders.isEmpty else { return }
        let available = ScenarioFolders.list(scenariosDir: project.scenariosDir)
        guard folders.allSatisfy({ !available.contains($0) }) else { return }  // 1つでも実在すれば続行
        let availableText = available.isEmpty ? "none" : available.joined(separator: ", ")
        throw ValidationError(
            "none of the --folder names exist in \(project.name) "
            + "(\(folders.joined(separator: ", "))); available: \(availableText)."
            + " Every entry of fleet \"\(fleetName)\" would have 0 scenarios; aborting before dispatch"
            + " (docs/remote-runner.md §13)")
    }

    // MARK: - subprocess

    private static func buildArgs(
        project: String, entry: FleetRunEntry, scenarios: [String], folders: [String],
        heal: Bool, noHeal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
        fastInput: Bool, enableAnimations: Bool, performanceMode: Bool,
        forceLock: Bool, remoteDir: String?, remoteTimeout: Int?, remoteArtifacts: String,
        quiet: Bool
    ) -> [String] {
        var args = ["run", "--project", project, "--profile", entry.profile]
        if entry.host != "local" {
            args += ["--host", entry.host]
            if forceLock { args += ["--force-lock"] }
            if let remoteDir { args += ["--remote-dir", remoteDir] }
            if let remoteTimeout { args += ["--remote-timeout", String(remoteTimeout)] }
            if remoteArtifacts != "collect" { args += ["--remote-artifacts", remoteArtifacts] }
        }
        if !scenarios.isEmpty { args += ["--scenario"] + scenarios }
        if !folders.isEmpty { args += ["--folder"] + folders }
        if heal { args += ["--heal"] }
        if noHeal { args += ["--no-heal"] }
        if noLPT { args += ["--no-lpt"] }
        if let lptHistoryRuns { args += ["--lpt-history-runs", String(lptHistoryRuns)] }
        if fastInput { args += ["--fast-input"] }
        if enableAnimations { args += ["--enable-animations"] }
        if performanceMode { args += ["--performance"] }
        if quiet { args += ["--quiet"] }
        return args
    }

    /// 実行中の ftester バイナリ自身の絶対パス(このプロセスを子として再起動する)
    private static func selfBinaryPath() -> String {
        if let url = Bundle.main.executableURL {
            return url.resolvingSymlinksInPath().path
        }
        return CommandLine.arguments[0]
    }

    /// 子の stdout+stderr を1本のパイプへ合流させ、行単位で `[<host>] ` を前置して中継する。
    /// 読み取りは RemoteRunDispatcher.runInheritedWithLineRewrite と同じ規律(専用スレッドで
    /// ブロッキング読み取り、完了は AsyncStream で待つ)
    private static func runEntry(binary: String, args: [String], hostLabel: String) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exitStream = ProcessExitWait.prepare(process)
        do {
            try process.run()
        } catch {
            log("[\(hostLabel)] error: failed to launch subprocess: \(error.localizedDescription)")
            return 127
        }

        let readHandle = pipe.fileHandleForReading
        let readDone = DispatchSemaphore(value: 0)
        let splitter = StreamLineSplitter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = readHandle.readData(ofLength: 65536)
                if chunk.isEmpty { break }   // 子の終了による書込端クローズで EOF
                for line in splitter.feed(chunk) { logLine(host: hostLabel, line: line) }
            }
            readDone.signal()
        }
        for await _ in exitStream {}
        readDone.wait()
        if let remaining = splitter.flush() { logLine(host: hostLabel, line: remaining) }
        return process.terminationStatus
    }

    // MARK: - 出力(print を使わない。RemoteRunDispatcher.log と同じ規律 ——
    // stdout が端末でないと行バッファが効かず、分単位の無音が「止まった」と誤解される)

    /// 複数エントリが並行に書くので、1行分を1回の write にまとめて lock で直列化する
    /// (PIPE_BUF を超える長い行が他エントリの行と噛み合って文字化けするのを防ぐ)
    private static let outputLock = NSLock()

    private static func logLine(host: String, line: String) {
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(Data("[\(host)] \(line)\n".utf8))
    }

    private static func log(_ message: String) {
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private static func printSummary(fleetName: String, outcomes: [FleetEntryOutcome]) {
        let header = ["HOST", "PROFILE", "RESULT", "TIME"]
        var rows = [header]
        rows.append(contentsOf: outcomes.map { outcome in
            [outcome.host, outcome.profile,
             outcome.exitCode == 0 ? "✅ pass" : "❌ fail (exit \(outcome.exitCode))",
             String(format: "%.1fs", outcome.duration)]
        })
        let widths = (0..<header.count).map { col in rows.map { $0[col].count }.max() ?? 0 }
        var lines = ["==> fleet \"\(fleetName)\" summary"]
        for row in rows {
            lines.append(zip(row, widths)
                .map { text, width in text + String(repeating: " ", count: max(0, width - text.count)) }
                .joined(separator: "  "))
        }
        let failed = outcomes.filter { $0.exitCode != 0 }.count
        lines.append("\(outcomes.count) entr\(outcomes.count == 1 ? "y" : "ies"): "
            + "\(outcomes.count - failed) passed, \(failed) failed "
            + "(aggregate exit \(FleetProfile.aggregateExitCode(outcomes.map(\.exitCode))))")
        log(lines.joined(separator: "\n"))
    }
}
