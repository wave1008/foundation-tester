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
        split: Bool, quiet: Bool, junit: String?
    ) async throws -> Int32 {
        try preflightFolders(folders, project: project, fleetName: fleetName)

        // --junit: 各エントリの子プロセスへ一時パスの --junit を渡し、全エントリ終了後に
        // FTCore.JUnitMerge で1本へ結合する(docs/remote-runner.md §8)。--split でも同じ
        // 仕組みを使うため一時ディレクトリの生成・削除はここで一度だけ行う
        let junitTempDir = try makeJUnitTempDir(requested: junit)
        defer { if let junitTempDir { try? FileManager.default.removeItem(at: junitTempDir) } }

        // --split は別経路(FleetSplit.swift の項参照)。**この分岐より下は --junit 配線を除き無改修**
        // (プレーンな --fleet の挙動を1バイトも変えない契約)
        if split {
            return try await runSplit(
                project: project, fleetName: fleetName, fleet: fleet,
                scenarios: scenarios, folders: folders,
                heal: heal, noHeal: noHeal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
                fastInput: fastInput, enableAnimations: enableAnimations, performanceMode: performanceMode,
                forceLock: forceLock, remoteDir: remoteDir, remoteTimeout: remoteTimeout,
                remoteArtifacts: remoteArtifacts, quiet: quiet, junit: junit, junitTempDir: junitTempDir)
        }

        let binary = selfBinaryPath()
        log("==> fleet \"\(fleetName)\": launching \(fleet.runs.count) entr"
            + "\(fleet.runs.count == 1 ? "y" : "ies") in parallel")

        let outcomes = await withTaskGroup(of: (Int, FleetEntryOutcome).self) { group in
            for (index, entry) in fleet.runs.enumerated() {
                group.addTask {
                    let args = buildArgs(
                        project: project.name, host: entry.host, profile: entry.profile,
                        scenarios: scenarios, folders: folders,
                        heal: heal, noHeal: noHeal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
                        fastInput: fastInput, enableAnimations: enableAnimations,
                        performanceMode: performanceMode, forceLock: forceLock,
                        remoteDir: remoteDir, remoteTimeout: remoteTimeout,
                        remoteArtifacts: remoteArtifacts, quiet: quiet,
                        junitPath: entryJUnitPath(tempDir: junitTempDir, index: index))
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
        if let junit, let junitTempDir {
            mergeAndWriteJUnit(junit: junit, project: project.name, tempDir: junitTempDir,
                                entries: fleet.runs.enumerated().map { (host: $0.element.host, index: $0.offset) })
        }
        return FleetProfile.aggregateExitCode(outcomes.map(\.exitCode))
    }

    // MARK: - split(docs/remote-runner.md §8「シナリオバッチを複数 Mac に割り当てる」)

    /// **実績が無いシナリオの見積り**: このプロジェクトの既知シナリオの中央値を使う。
    /// プロジェクトごとに実行速度が大きく違うため、固定の秒数は使わない
    /// (`RemoteTimeout.seconds` の perScenario=600s はタイムアウトの悲観上限で、ここでの
    /// 「典型的な1本」の見積りとは文脈が違う定数なので流用しない)。
    ///
    /// **1件も実績が無い**(プロジェクト初回 run)ときは全シナリオが同じ重みになり、LPT は
    /// **本数での均等割り**に退化する。このとき重みの絶対値は割り当てに影響しない
    /// (全員が同じ値なら順序も選択も変わらない)ので、**根拠のある数を選ぶ問題自体が消える**。
    /// 1.0 は「重み1つぶん」という意味であって秒数ではない —— 表示する推定所要が
    /// 実時間に見えないよう、`printAssignment` は実績ゼロのとき推定を出さない。
    /// `FleetSplitTests.testAllUnknownDurationsSplitByCountRegardlessOfWeight` が
    /// 「値を変えても割り当てが変わらない」ことを固定する
    private static let unknownDurationUnitWeight = 1.0

    /// `--split`: シナリオ一覧をローカルで解決 → LPT で各エントリへ割り当て → 確定した
    /// --scenario を渡して子プロセスを起動する。空バケツのエントリはディスパッチしない
    private static func runSplit(
        project: TestProject, fleetName: String, fleet: FleetProfileDocument,
        scenarios: [String], folders: [String],
        heal: Bool, noHeal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
        fastInput: Bool, enableAnimations: Bool, performanceMode: Bool,
        forceLock: Bool, remoteDir: String?, remoteTimeout: Int?, remoteArtifacts: String,
        quiet: Bool, junit: String?, junitTempDir: URL?
    ) async throws -> Int32 {
        log("==> fleet \"\(fleetName)\" --split: building \(project.name) locally to resolve"
            + " the scenario list (plain --fleet skips this build)")
        try ScenarioHost.build(project: project, log: { log($0) })
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
            throw ValidationError("--split has 0 scenarios to distribute after filtering"
                + " (docs/remote-runner.md §8)")
        }

        let entryPlatforms = try fleet.runs.map { try resolveEntryPlatforms($0, project: project) }

        let historyRuns = max(1, lptHistoryRuns ?? LPTOrdering.defaultHistoryRuns)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        let since = Date().addingTimeInterval(-30 * 24 * 60 * 60)  // LPTOrdering.historyDays と同じ窓
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: since,
                                                  maxObservationsPerScenario: historyRuns)
        let durations = LPTScheduler.durations(from: records)
        // 実績ゼロ = 全員同じ重み → LPT は本数の均等割りに退化する(unknownDurationUnitWeight の項)
        let hasHistory = !durations.isEmpty
        let unknownDurationMs = medianMs(durations.map(\.medianMs)) ?? unknownDurationUnitWeight

        let buckets: [FleetSplit.Bucket]
        do {
            buckets = try FleetSplit.partition(
                scenarios: selected.map { (id: $0.id, platform: $0.platform) },
                durations: durations, entryPlatforms: entryPlatforms, unknownDurationMs: unknownDurationMs)
        } catch let error as FleetSplit.FleetSplitError {
            throw ValidationError("fleet \"\(fleetName)\" --split: \(error.localizedDescription)")
        }

        printAssignment(fleetName: fleetName, fleet: fleet, buckets: buckets, hasHistory: hasHistory)

        let byEntryIndex = Dictionary(uniqueKeysWithValues: buckets.map { ($0.entryIndex, $0.scenarioIDs) })
        let active = fleet.runs.enumerated().compactMap { index, entry -> (Int, FleetRunEntry, [String])? in
            let ids = byEntryIndex[index] ?? []
            return ids.isEmpty ? nil : (index, entry, ids)
        }
        guard !active.isEmpty else {
            log("==> fleet \"\(fleetName)\" --split: no entry was assigned a scenario; nothing to dispatch")
            return 0
        }

        let binary = selfBinaryPath()
        log("==> fleet \"\(fleetName)\" --split: dispatching \(active.count) of \(fleet.runs.count) entr"
            + "\(fleet.runs.count == 1 ? "y" : "ies") in parallel")

        let outcomes = await withTaskGroup(of: (Int, FleetEntryOutcome).self) { group in
            for (index, entry, ids) in active {
                group.addTask {
                    let args = buildArgs(
                        project: project.name, host: entry.host, profile: entry.profile,
                        scenarios: ids, folders: [],
                        heal: heal, noHeal: noHeal, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
                        fastInput: fastInput, enableAnimations: enableAnimations,
                        performanceMode: performanceMode, forceLock: forceLock,
                        remoteDir: remoteDir, remoteTimeout: remoteTimeout,
                        remoteArtifacts: remoteArtifacts, quiet: quiet,
                        junitPath: entryJUnitPath(tempDir: junitTempDir, index: index))
                    let start = Date()
                    let exitCode = await runEntry(binary: binary, args: args, hostLabel: entry.host)
                    return (index, FleetEntryOutcome(
                        host: entry.host, profile: entry.profile, exitCode: exitCode,
                        duration: Date().timeIntervalSince(start)))
                }
            }
            var collected: [Int: FleetEntryOutcome] = [:]
            for await (index, outcome) in group { collected[index] = outcome }
            return active.map { collected[$0.0]! }
        }

        printSplitSummary(fleetName: fleetName, fleet: fleet, outcomes: outcomes, buckets: buckets)
        // active だけを対象にする(0本割当で見送ったエントリは --junit を渡していないので
        // 「出力が無い」合成失敗の対象に含めない)
        if let junit, let junitTempDir {
            mergeAndWriteJUnit(junit: junit, project: project.name, tempDir: junitTempDir,
                                entries: active.map { (host: $0.1.host, index: $0.0) })
        }
        return FleetProfile.aggregateExitCode(outcomes.map(\.exitCode))
    }

    /// エントリが走らせられる platform 集合を、実際の run と同じ規則(ProfileResolver.resolve)で
    /// 求める。**マシンプロファイルはプロジェクト資産(git 管理)で、実行のたびにリモートへ
    /// 転送される**ので、リモートエントリでも SSH せずローカルの clone から解決できる
    /// (docs/remote-runner.md §8)。どのマシンプロファイルかは**実行プロファイルの `machine`**
    /// が決める —— 以前は登録簿にキャッシュしたリモートのマシン名を使っていたが、
    /// 「この機械の登録名」は 2026-08-17 に廃止した(ProfileResolver.determineMachine の宣言)
    private static func resolveEntryPlatforms(
        _ entry: FleetRunEntry, project: TestProject
    ) throws -> Set<String> {
        let (machineName, _) = try ProfileResolver.determineMachine(
            project: project, runProfileName: entry.profile)
        let resolved = try ProfileResolver.resolve(
            project: project, runName: entry.profile, machineName: machineName)
        return Set(resolved.devices.map(\.platform))
    }

    private static func medianMs(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// 実行前の割り当て表(エントリ / ホスト / 本数 / 推定所要)。0本のエントリも並べて出す
    /// —— 「なぜそのホストへ行かなかったか」を後から run ログの外で探させない。
    /// **実績が1件も無いときは推定を出さない**(重みは「1本ぶん」であって秒ではないので、
    /// 秒として見せると読み手が実時間と誤読する。`unknownDurationUnitWeight` の項)
    private static func printAssignment(fleetName: String, fleet: FleetProfileDocument,
                                        buckets: [FleetSplit.Bucket], hasHistory: Bool) {
        let byIndex = Dictionary(uniqueKeysWithValues: buckets.map { ($0.entryIndex, $0) })
        let header = hasHistory ? ["HOST", "PROFILE", "SCENARIOS", "EST."] : ["HOST", "PROFILE", "SCENARIOS"]
        var rows = [header]
        for (index, entry) in fleet.runs.enumerated() {
            let count = byIndex[index]?.scenarioIDs.count ?? 0
            var row = [entry.host, entry.profile, count == 0 ? "0 (skip)" : String(count)]
            if hasHistory {
                row.append(String(format: "%.1fs", (byIndex[index]?.estimatedMs ?? 0) / 1000))
            }
            rows.append(row)
        }
        let widths = (0..<header.count).map { col in rows.map { $0[col].count }.max() ?? 0 }
        let total = buckets.reduce(0) { $0 + $1.scenarioIDs.count }
        var lines = ["==> fleet \"\(fleetName)\" --split: assignment (\(total) scenario(s) across "
            + "\(fleet.runs.count) entr\(fleet.runs.count == 1 ? "y" : "ies"))"]
        for row in rows {
            lines.append(zip(row, widths)
                .map { text, width in text + String(repeating: " ", count: max(0, width - text.count)) }
                .joined(separator: "  "))
        }
        log(lines.joined(separator: "\n"))
    }

    /// 実行後の集計。プレーンな --fleet の printSummary とは別関数(あちらの出力を1バイトも
    /// 変えないため)。skip したエントリも1行として出す
    private static func printSplitSummary(
        fleetName: String, fleet: FleetProfileDocument,
        outcomes: [FleetEntryOutcome], buckets: [FleetSplit.Bucket]
    ) {
        let byIndex = Dictionary(uniqueKeysWithValues: buckets.map { ($0.entryIndex, $0.scenarioIDs.count) })
        let outcomeByHost = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.host, $0) })
        let header = ["HOST", "PROFILE", "SCENARIOS", "RESULT", "TIME"]
        var rows = [header]
        for (index, entry) in fleet.runs.enumerated() {
            let count = byIndex[index] ?? 0
            if let outcome = outcomeByHost[entry.host] {
                rows.append([entry.host, entry.profile, String(count),
                             outcome.exitCode == 0 ? "✅ pass" : "❌ fail (exit \(outcome.exitCode))",
                             String(format: "%.1fs", outcome.duration)])
            } else {
                rows.append([entry.host, entry.profile, "0", "⏭️ skip (0 scenarios assigned)", "-"])
            }
        }
        let widths = (0..<header.count).map { col in rows.map { $0[col].count }.max() ?? 0 }
        var lines = ["==> fleet \"\(fleetName)\" --split summary"]
        for row in rows {
            lines.append(zip(row, widths)
                .map { text, width in text + String(repeating: " ", count: max(0, width - text.count)) }
                .joined(separator: "  "))
        }
        let failed = outcomes.filter { $0.exitCode != 0 }.count
        let skipped = fleet.runs.count - outcomes.count
        lines.append("\(outcomes.count) entr\(outcomes.count == 1 ? "y" : "ies") dispatched: "
            + "\(outcomes.count - failed) passed, \(failed) failed, \(skipped) skipped "
            + "(aggregate exit \(FleetProfile.aggregateExitCode(outcomes.map(\.exitCode))))")
        log(lines.joined(separator: "\n"))
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

    /// 子プロセスの引数列。フリート("1エントリ = 1ホスト + 1プロファイル")と
    /// デバイス単位 host のサブ実行("同じプロファイルをホストごとに、担当デバイスだけで")の
    /// **両方がここを通る** —— run のフラグを足すときに片方だけ中継し忘れると、そのフラグは
    /// 黙って無視される(リモートはプロファイルの既定で走る)
    static func buildArgs(
        project: String, host: String, profile: String,
        deviceNames: [String] = [], deviceHost: String? = nil,
        scenarios: [String], folders: [String],
        heal: Bool, noHeal: Bool, noLPT: Bool, lptHistoryRuns: Int?,
        fastInput: Bool, enableAnimations: Bool, performanceMode: Bool,
        forceLock: Bool, remoteDir: String?, remoteTimeout: Int?, remoteArtifacts: String,
        quiet: Bool, junitPath: String?
    ) -> [String] {
        var args = ["run", "--project", project, "--profile", profile]
        // "local" エントリも常に --host を渡す(欠陥3・2026-08-17)。子プロセスは自分自身が
        // MachineHostDispatch を再適用するため、--host を省略すると「未指定」と区別が付かず、
        // entry.profile が引くマシンプロファイルに host が設定されていると子がそこへ自動
        // ディスパッチしてしまい、{"host":"local"} と書いた意味が失われる(重複ホスト拒否も
        // 無意味になる)。"local" を明示すれば MachineHostDispatch.resolve がそこで止める
        // (RunProfile.swift 参照)。--force-lock 等のリモート専用フラグは引き続きリモートのみ
        if host != "local" {
            args += ["--host", host]
            if forceLock { args += ["--force-lock"] }
            if let remoteDir { args += ["--remote-dir", remoteDir] }
            if let remoteTimeout { args += ["--remote-timeout", String(remoteTimeout)] }
            if remoteArtifacts != "collect" { args += ["--remote-artifacts", remoteArtifacts] }
        } else {
            args += ["--host", "local"]
        }
        if !deviceNames.isEmpty { args += ["--device"] + deviceNames }
        // **ホストも渡す** —— 一意なのは (host, name) なので、名前だけだと子が別の機械の
        // 同名デバイスまで掴む(2026-08-17 に実走で確認。RunProfile.filteringDevices の宣言)
        if let deviceHost { args += ["--device-host", deviceHost] }
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
        // リモートエントリでも同じ --junit 中継でよい: RemoteRunDispatcher.dispatch が
        // localJUnitPath(= このパス)へリモートの JUnit を回収して書く(RemoteRunDispatcher.swift)
        if let junitPath { args += ["--junit", junitPath] }
        return args
    }

    // MARK: - --junit の集約(docs/remote-runner.md §8)

    /// エントリごとの一時 --junit 出力を集める作業ディレクトリ。junit が指定されていなければ nil
    /// (通常の --fleet の挙動を変えない)
    static func makeJUnitTempDir(requested junit: String?) throws -> URL? {
        guard junit != nil else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftester-fleet-junit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// エントリの index ごとに固定のファイル名にする(host は "user@host" 等ファイル名に
    /// 使えない文字を含みうるため、host 文字列は使わない)
    static func entryJUnitPath(tempDir: URL?, index: Int) -> String? {
        tempDir?.appendingPathComponent("entry-\(index).xml").path
    }

    /// entries に挙げたぶんだけを FTCore.JUnitMerge へ渡して結合する。**渡すのはディスパッチした
    /// (= --junit を付けて子プロセスを起動した)エントリだけにする** —— --split で0本割当のため
    /// 送らなかったエントリまで含めると「出力が無い」合成失敗にされ、走らせてもいない結果が
    /// 赤として報告される。書き込み失敗は run の成否を変えない(warn のみ。単発 --junit と同じ規律)
    static func mergeAndWriteJUnit(
        junit: String, project: String, tempDir: URL, entries: [(host: String, index: Int)]
    ) {
        let merged = entries.map { entry -> JUnitMerge.Entry in
            let path = tempDir.appendingPathComponent("entry-\(entry.index).xml").path
            let xml = try? String(contentsOfFile: path, encoding: .utf8)
            return JUnitMerge.Entry(host: entry.host, xml: (xml?.isEmpty == false) ? xml : nil)
        }
        do {
            let xml = JUnitMerge.merge(merged, project: project)
            let url = URL(fileURLWithPath: junit)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: url, atomically: true, encoding: .utf8)
            log("📄 JUnit report: \(junit) (\(entries.count) entr\(entries.count == 1 ? "y" : "ies") merged)")
        } catch {
            log("⚠️ Failed to write the merged JUnit report: \(junit) (\(error.localizedDescription))")
        }
    }

    /// 実行中の ftester バイナリ自身の絶対パス(このプロセスを子として再起動する)
    static func selfBinaryPath() -> String {
        if let url = Bundle.main.executableURL {
            return url.resolvingSymlinksInPath().path
        }
        return CommandLine.arguments[0]
    }

    /// 子の stdout+stderr を1本のパイプへ合流させ、行単位で `[<host>] ` を前置して中継する。
    /// 読み取りは RemoteRunDispatcher.runInheritedWithLineRewrite と同じ規律(専用スレッドで
    /// ブロッキング読み取り、完了は AsyncStream で待つ)
    static func runEntry(binary: String, args: [String], hostLabel: String) async -> Int32 {
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

    static func logLine(host: String, line: String) {
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(Data("[\(host)] \(line)\n".utf8))
    }

    /// 子プロセスの中継行と混ざらないよう outputLock 越しに書く(DeviceHostRunner も同じ口を使う)
    static func log(_ message: String) {
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
