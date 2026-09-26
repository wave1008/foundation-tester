// VSCode拡張ダッシュボード向け: 実行結果DB(RunResultsStore/RunResultsQuery)の集計を
// まとめて1回のJSONで返す(fleetest api results)。診断は stderr のみ(ApiCommands.swift と同じ流儀)。
// 出力ペイロードの契約(フィールド名・trend の省略可否): vscode-fleetest/src/dashboardModel.ts と同期。
// 出力は <project>/.fleetest/results-cache/ にキャッシュする(有効条件と厳密性は
// FTCore.ResultsOutputCache の冒頭)。--no-cache は読まないだけで、書き直しは常に行う

import ArgumentParser
import Foundation
import FTCore
import FTRemote

struct ApiResultsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "results",
        abstract: "Aggregate the run-results database (results/) — runs/summary/flaky/devices/trend/slow/insights —"
            + " and print it all as JSON on stdout (diagnostics on stderr only)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Start of the period: a duration (e.g. 90s/30m/2h/30d), a date (YYYY-MM-DD) or an epoch (@1757280000)")
    var since: String = "90d"

    @Option(help: "Number of entries to include in runs (descending by runID)")
    var limit: Int = 50

    @Option(name: .customLong("min-runs"), help: ArgumentHelp(
        "Minimum number of runs before a scenario is considered for flakiness (flaky looks at each scenario's"
        + " last \(RunResultsQuery.recentScenarioRunsWindow) runs, so at most \(RunResultsQuery.recentScenarioRunsWindow))"))
    var minRuns: Int = 5

    @Option(help: "Scenario ID whose trend (run history) to output; omitted unless given")
    var scenario: String?

    @Flag(name: .customLong("no-cache"),
          help: "Recompute instead of reading the output cache (<project>/.fleetest/results-cache/); the cache is rewritten either way")
    var noCache = false

    func validate() throws {
        // flaky は各シナリオの直近 N run しか見ないので、N を超える --min-runs は必ず 0 件になる(黙って効かない)
        guard minRuns <= RunResultsQuery.recentScenarioRunsWindow else {
            throw ValidationError("--min-runs \(minRuns) can never match: flaky looks at each scenario's last"
                + " \(RunResultsQuery.recentScenarioRunsWindow) runs (use `fleetest results flaky` for the full history)")
        }
    }

    func run() throws {
        let testProject = try ScenarioHost.project(named: project)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: testProject.rootURL)
        guard let sinceDate = RunResultsQuery.parseSince(since) else {
            throw ValidationError(TimeBoundParse.rejection(option: "--since", raw: since))
        }
        let isoFormatter = ISO8601DateFormatter()
        let generatedAt = isoFormatter.string(from: Date())
        // windowKey と同じ書式(ISO8601 "Z")。出力の since と有効判定の sinceKey は同じ値
        let sinceKey = RunResultsStore.windowKey(sinceDate)
        let stateDir = testProject.stateDir
        // insights の retiredScenarios は results/ の走査ではなく scenarios/ の**ソース**走査
        // (definedScenarioClasses(of:) → ScenarioFolders.classFileMap)に依存するので、
        // scanDigest(results/ 側)だけでは追随しない(シナリオを消しても次の run まで
        // 古い出力を返し、`--no-cache` と食い違う)。同じ走査規則の指紋
        // (ScenarioFolders.directorySignature。他に使い道が無く、テストだけが当てていた)を
        // 鍵に混ぜる
        let scenariosDigest = ScenarioFolders.directorySignature(scenariosDir: testProject.scenariosDir)
            .joined(separator: "\u{1}")
        let key = ResultsOutputCache.argumentsKey(
            arguments: [testProject.name, since, String(limit), String(minRuns), scenariosDigest],
            executable: Bundle.main.executableURL)
        // 指紋は走査より先に取る(順序の理由は scanFingerprint の doc)
        let scanDigest = RunResultsStore.scanFingerprint(resultsDir: resultsDir, since: sinceDate)

        if !noCache,
           let output = cachedOutput(stateDir: stateDir, resultsDir: resultsDir, key: key,
                                     scanDigest: scanDigest, sinceKey: sinceKey, generatedAt: generatedAt) {
            ConsoleOut.out(output)
            return
        }

        let (runs, entries) = RunResultsStore.scanRunsAndRecords(
            resultsDir: resultsDir, since: sinceDate,
            packCacheDir: RunRecordPack.cacheDir(stateDir: stateDir),
            executableKey: ResultsOutputCache.executableFingerprint(executable: Bundle.main.executableURL))
        // パック経由の record は集計用に縮小済み(RunRecordPack.trimmedForStorage)。
        // 集計(summary/flaky/devices/slow/insights/performance/runStats)は
        // その縮小で困らない(timeline から読むのは notes だけ。TimelineNotesOnlyScanTests が保証)。
        // trend(--scenario)だけは元ファイルを読み直す(trendRecords)
        let records = entries.map(\.record)
        let recentRuns = RunResultsQuery.recentRuns(runs, limit: limit)

        let body = ApiResultsBody(
            schemaVersion: 1,
            project: testProject.name,
            runs: recentRuns,
            summary: RunResultsQuery.scenarioSummary(
                records, recentRuns: RunResultsQuery.recentScenarioRunsWindow),
            flaky: RunResultsQuery.flakyScenarios(
                records, minRuns: minRuns, recentRuns: RunResultsQuery.recentScenarioRunsWindow),
            deviceHealth: RunResultsQuery.deviceHealth(runs: runs, records: records),
            slow: RunResultsQuery.slowTests(records, limit: 10),
            insights: RunResultsQuery.insights(records: records, runs: runs,
                                               definedClasses: definedScenarioClasses(of: testProject)),
            performance: RunResultsQuery.performanceReport(records: records, runs: runs),
            machines: RemoteHostFactsStore.aliasPairs(dir: RemoteHostFactsStore.dir(project: testProject))
                .map { MachineAliasEntry(host: $0.host, machine: $0.machine) },
            runStats: RunResultsQuery.runStats(runs: recentRuns, records: records))

        let encoder = Self.makeEncoder()
        let bodyJSON = String(decoding: try encoder.encode(body), as: UTF8.self)
        let trendJSON = try scenario.map { id in
            let fullRecords = Self.trendRecords(entries: entries, scenarioID: id)
            return String(decoding: try encoder.encode(RunResultsQuery.trend(fullRecords, scenarioID: id)), as: UTF8.self)
        }

        // 窓に含めた最古の startedAt(run.json と記録の両方。どちらかが落ちれば出力が変わる)
        let oldestIncluded = (runs.map(\.startedAt) + records.map(\.startedAt)).min()
        let resultsPrefix = resultsDir.path + "/"
        let trendFiles = Dictionary(grouping: entries, by: \.record.scenarioID).mapValues { group in
            group.map { entry -> String in
                let path = entry.url.path
                return path.hasPrefix(resultsPrefix) ? String(path.dropFirst(resultsPrefix.count)) : path
            }
        }
        ResultsOutputCache.write(
            ResultsOutputCache.Entry(key: key, scanDigest: scanDigest, sinceKey: sinceKey,
                                     oldestIncludedStartedAt: oldestIncluded, body: bodyJSON),
            trendIndex: ResultsOutputCache.TrendIndex(scanDigest: scanDigest, files: trendFiles),
            stateDir: stateDir)

        guard let output = ResultsOutputCache.compose(generatedAt: generatedAt, since: sinceKey,
                                                      trendJSON: trendJSON, body: bodyJSON) else {
            throw ValidationError("internal: the results body did not encode as a JSON object")
        }
        ConsoleOut.out(output)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func diagnose(_ message: String) {
        ConsoleOut.err("results cache: \(message)")
    }

    /// キャッシュが有効なら合成済みの出力(--scenario 付きは索引から trend を読んで足す)。
    /// 無効・読めない・索引が指紋と食い違う場合は nil(= 全部計算する)
    private func cachedOutput(stateDir: URL, resultsDir: URL, key: String, scanDigest: String,
                              sinceKey: String, generatedAt: String) -> String? {
        let (entry, readable) = ResultsOutputCache.readEntry(stateDir: stateDir)
        if let miss = ResultsOutputCache.validate(entry, readable: readable, key: key,
                                                  scanDigest: scanDigest, sinceKey: sinceKey) {
            Self.diagnose("miss (\(miss))")
            return nil
        }
        guard let entry else { return nil }
        var trendJSON: String?
        if let scenario {
            guard let index = ResultsOutputCache.readTrendIndex(stateDir: stateDir),
                  index.formatVersion == ResultsOutputCache.formatVersion,
                  index.scanDigest == scanDigest else {
                Self.diagnose("miss (trend index)")
                return nil
            }
            let records = Self.records(index: index, scenarioID: scenario, resultsDir: resultsDir, sinceKey: sinceKey)
            guard let data = try? Self.makeEncoder().encode(RunResultsQuery.trend(records, scenarioID: scenario)) else {
                return nil
            }
            trendJSON = String(decoding: data, as: UTF8.self)
        }
        guard let output = ResultsOutputCache.compose(generatedAt: generatedAt, since: sinceKey,
                                                      trendJSON: trendJSON, body: entry.body) else {
            Self.diagnose("miss (body)")
            return nil
        }
        Self.diagnose("hit")
        return output
    }

    /// 索引が指す記録だけを読む。読み飛ばし規律は RunResultsStore.scanRecords と同じ
    /// (壊れたファイル・新しすぎる schemaVersion・since より前)
    private static func records(index: ResultsOutputCache.TrendIndex, scenarioID: String,
                                resultsDir: URL, sinceKey: String) -> [ScenarioRunRecord] {
        let decoder = JSONDecoder()
        return (index.files[scenarioID] ?? []).compactMap { relative -> ScenarioRunRecord? in
            let url = relative.hasPrefix("/") ? URL(fileURLWithPath: relative)
                                              : resultsDir.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(ScenarioRunRecord.self, from: data),
                  record.schemaVersion <= RunRecordSchema.current,
                  record.startedAt >= sinceKey else { return nil }
            return record
        }
    }

    /// trend(--scenario)専用: `entries` の record を使わず、対象シナリオぶんだけ `entries.url`
    /// (元の scenarios/*.json)を読み直す。**パック経由の record は timeline を縮小済み**
    /// (RunRecordPack.trimmedForStorage)なので、trend が返す timeline 付きの記録には使えない。
    /// キャッシュ経路(上の `records(index:...)`)も同じ「url から読み直す」方式なので、
    /// ヒット/ミスで trend の中身が変わらない
    private static func trendRecords(entries: [RunResultsStore.ScannedRecord], scenarioID: String) -> [ScenarioRunRecord] {
        let decoder = JSONDecoder()
        return entries.filter { $0.record.scenarioID == scenarioID }.compactMap { entry -> ScenarioRunRecord? in
            guard let data = try? Data(contentsOf: entry.url),
                  let record = try? decoder.decode(ScenarioRunRecord.self, from: data) else { return nil }
            return record
        }
    }
}

/// fleetest api results の出力のうち、呼ぶたびに変わる since/generatedAt と --scenario 依存の trend を
/// 除いた部分(= キャッシュの body)。印字形は ResultsOutputCache.compose が組む
private struct ApiResultsBody: Encodable {
    let schemaVersion: Int
    let project: String
    let runs: [RunMetaRecord]
    let summary: [RunResultsQuery.ScenarioSummaryRow]
    let flaky: [RunResultsQuery.FlakyRow]
    let deviceHealth: [RunResultsQuery.DeviceHealthRow]
    let slow: [RunResultsQuery.SlowTestRow]
    let insights: [RunResultsQuery.InsightRow]
    let performance: RunResultsQuery.PerformanceReport
    /// 記録の host(ホスト名)→ この Mac の登録名(machine)の読み替え表(facts キャッシュ由来)。
    /// 記録・runID は host のまま —— エイリアスは改名されうるので表示時にだけ引く
    let machines: [MachineAliasEntry]
    /// runs と同じ集合の per-run 時間統計(壁時計・テスト時間。表示側が runGroup 単位に畳む)
    let runStats: [RunResultsQuery.RunStatsRow]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, project, runs, summary, flaky, deviceHealth,
             slow, insights, performance, machines, runStats
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(project, forKey: .project)
        try container.encode(runs, forKey: .runs)
        try container.encode(summary, forKey: .summary)
        try container.encode(flaky, forKey: .flaky)
        try container.encode(deviceHealth, forKey: .deviceHealth)
        try container.encode(slow, forKey: .slow)
        try container.encode(insights, forKey: .insights)
        try container.encode(performance, forKey: .performance)
        try container.encode(machines, forKey: .machines)
        try container.encode(runStats, forKey: .runStats)
    }
}

/// host(記録の鍵)→ machine(表示名)の1組。TS 側契約: dashboardModel.ts の MachineAliasRow
struct MachineAliasEntry: Encodable {
    let host: String
    let machine: String
}
