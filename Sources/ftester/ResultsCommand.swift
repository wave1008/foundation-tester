// ResultsCommand.swift
// results/ 配下(RunResultsStore)の実行結果 DB を集計して表示する CLI。
// 集計ロジックは RunResultsQuery(FTCore、vscode 拡張の api コマンドと共用)に置き、
// このファイルは表示整形とオプション解釈のみを担当する。

import ArgumentParser
import Foundation
import FTCore

struct ResultsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "results",
        abstract: "実行結果 DB(results/)を集計・分析する",
        subcommands: [
            ResultsListCommand.self,
            ResultsSummaryCommand.self,
            ResultsFlakyCommand.self,
            ResultsTrendCommand.self,
            ResultsDevicesCommand.self,
            ResultsSlowCommand.self,
            ResultsInsightsCommand.self,
        ])
}

/// results サブコマンド共通オプション
struct ResultsQueryOptions: ParsableArguments {
    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "期間の開始。30d/12h のような相対指定、または YYYY-MM-DD(省略時は 90d)")
    var since: String = "90d"

    @Flag(help: "結果を JSON(1 行)で出力する")
    var json = false

    /// プロジェクト・resultsDir・since の Date を解決する。--since 形式不正はここで弾く
    func resolve() throws -> (project: TestProject, resultsDir: URL, sinceDate: Date) {
        let testProject = try ScenarioHost.project(named: project)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: testProject.rootURL)
        guard let sinceDate = RunResultsQuery.parseSince(since) else {
            throw ValidationError("--since の形式が不正です: \(since)(例: 30d, 12h, 2026-06-01)")
        }
        return (testProject, resultsDir, sinceDate)
    }
}

/// --json 指定時の共通出力(sortedKeys・スラッシュ非エスケープの 1 行 JSON)
private func printResultsJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8)!)
}

/// startedAt(ISO8601 UTC)をローカルタイムゾーンの人間可読表示に変換する。パース不能ならそのまま返す
private func formatLocal(_ iso8601: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso8601) else { return iso8601 }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: date)
}

/// 日本語混じりでも桁数(character count)基準で揃える簡易テーブル(半角想定・厳密な幅計算はしない)
private enum SimpleTable {
    static func render(headers: [String], rows: [[String]]) -> String {
        let columnCount = headers.count
        var widths = headers.map(\.count)
        for row in rows {
            for i in 0..<columnCount {
                widths[i] = max(widths[i], (i < row.count ? row[i] : "").count)
            }
        }
        func padRow(_ cells: [String]) -> String {
            (0..<columnCount).map { i -> String in
                let cell = i < cells.count ? cells[i] : ""
                return cell + String(repeating: " ", count: widths[i] - cell.count)
            }.joined(separator: "  ")
        }
        var lines = [padRow(headers)]
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        lines.append(contentsOf: rows.map(padRow))
        return lines.joined(separator: "\n")
    }
}

// MARK: - list

struct ResultsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "run 一覧を新しい順に表示する")

    @OptionGroup var options: ResultsQueryOptions

    @Option(help: "表示件数")
    var limit: Int = 20

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let runs = RunResultsStore.scanRuns(resultsDir: resultsDir, since: sinceDate)
        let rows = RunResultsQuery.recentRuns(runs, limit: limit)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        guard !rows.isEmpty else {
            print("該当する run がありません")
            return
        }
        let headers = ["runID", "日時", "trigger", "profile", "machine", "passed/failed/total"]
        let tableRows = rows.map { meta -> [String] in
            let counts: String
            if let total = meta.total, let passed = meta.passed, let failed = meta.failed {
                counts = "\(passed)/\(failed)/\(total)"
            } else {
                counts = "(未完了)"
            }
            return [meta.runID, formatLocal(meta.startedAt), meta.trigger,
                    meta.profile ?? "-", meta.machine, counts]
        }
        print(SimpleTable.render(headers: headers, rows: tableRows))
    }
}

// MARK: - summary

struct ResultsSummaryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summary", abstract: "シナリオ別の実行回数・成功率・所要時間を集計する(成功率昇順)")

    @OptionGroup var options: ResultsQueryOptions

    @Option(help: "対象シナリオ ID(省略時は全シナリオ)")
    var scenario: String?

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let filtered = scenario.map { id in records.filter { $0.scenarioID == id } } ?? records
        let rows = RunResultsQuery.scenarioSummary(filtered)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        guard !rows.isEmpty else {
            print("該当するシナリオがありません")
            return
        }
        let headers = ["シナリオID", "実行回数", "成功率", "平均ms", "中央値ms", "最終実行", "最終結果"]
        let tableRows = rows.map { row -> [String] in
            [row.scenarioID, String(row.runs), String(format: "%.1f%%", row.successRate),
             row.avgDurationMs.map { String(format: "%.0f", $0) } ?? "-",
             row.medianDurationMs.map { String(format: "%.0f", $0) } ?? "-",
             row.lastRunAt.map(formatLocal) ?? "-",
             row.lastPassed.map { $0 ? "✅" : "❌" } ?? "-"]
        }
        print(SimpleTable.render(headers: headers, rows: tableRows))
    }
}

// MARK: - flaky

struct ResultsFlakyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flaky", abstract: "pass/fail が混在する不安定なシナリオを不安定度順に表示する")

    @OptionGroup var options: ResultsQueryOptions

    @Option(name: .customLong("min-runs"), help: "対象にする最小実行回数")
    var minRuns: Int = 5

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let rows = RunResultsQuery.flakyScenarios(records, minRuns: minRuns)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        guard !rows.isEmpty else {
            print("不安定なシナリオはありません(--min-runs \(minRuns) 以上・pass/fail 混在が対象)")
            return
        }
        let headers = ["シナリオID", "実行回数", "失敗率", "遷移スコア", "直近の結果(新→旧)"]
        let tableRows = rows.map { row -> [String] in
            [row.scenarioID, String(row.runs), String(format: "%.1f%%", row.failureRate),
             String(format: "%.2f", row.flakinessScore),
             row.recentResults.map { $0 ? "✅" : "❌" }.joined()]
        }
        print(SimpleTable.render(headers: headers, rows: tableRows))
    }
}

// MARK: - trend

struct ResultsTrendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trend", abstract: "1 シナリオの実行履歴を時系列(古い順)で表示する")

    @OptionGroup var options: ResultsQueryOptions

    @Option(help: "対象シナリオ ID")
    var scenario: String

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let rows = RunResultsQuery.trend(records, scenarioID: scenario)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        guard !rows.isEmpty else {
            print("該当する実行履歴がありません: \(scenario)")
            return
        }
        // バーはスキップ合成レコードを除いた最大 durationMs を 20 文字とした相対値
        let maxDuration = rows.filter { !RunResultsQuery.isSkippedSynthetic($0) }
            .map(\.durationMs).max() ?? 0
        let headers = ["startedAt", "runID", "passed", "durationMs", "worker", "machine", "bar"]
        let tableRows = rows.map { record -> [String] in
            let bar: String
            if RunResultsQuery.isSkippedSynthetic(record) || maxDuration == 0 {
                bar = ""
            } else {
                let length = max(1, Int((Double(record.durationMs) / Double(maxDuration)) * 20))
                bar = String(repeating: "█", count: length)
            }
            return [formatLocal(record.startedAt), record.runID, record.passed ? "✅" : "❌",
                    String(record.durationMs), record.worker ?? "-", record.machine, bar]
        }
        print(SimpleTable.render(headers: headers, rows: tableRows))
    }
}

// MARK: - devices

struct ResultsDevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices", abstract: "worker(デバイス)別・platform 別に実行回数・成功率を集計する")

    @OptionGroup var options: ResultsQueryOptions

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let report = RunResultsQuery.deviceSummary(records)

        if options.json {
            try printResultsJSON(report)
            return
        }
        guard !report.byWorker.isEmpty else {
            print("該当する実行がありません")
            return
        }
        print("[worker 別]")
        print(SimpleTable.render(
            headers: ["worker", "実行回数", "成功率", "平均ms"],
            rows: report.byWorker.map { row in
                [row.worker, String(row.runs), String(format: "%.1f%%", row.successRate),
                 row.avgDurationMs.map { String(format: "%.0f", $0) } ?? "-"]
            }))
        print("\n[platform 別]")
        print(SimpleTable.render(
            headers: ["platform", "実行回数", "成功率", "平均ms"],
            rows: report.byPlatform.map { row in
                [row.platform, String(row.runs), String(format: "%.1f%%", row.successRate),
                 row.avgDurationMs.map { String(format: "%.0f", $0) } ?? "-"]
            }))
    }
}

// MARK: - slow

struct ResultsSlowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slow", abstract: "平均所要時間が長いシナリオを遅い順に表示する")

    @OptionGroup var options: ResultsQueryOptions

    @Option(help: "表示件数")
    var limit: Int = 10

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let rows = RunResultsQuery.slowTests(records, limit: limit)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        guard !rows.isEmpty else {
            print("該当するシナリオがありません")
            return
        }
        let headers = ["シナリオID", "実行回数", "平均ms", "p90ms", "悪化率", "最遅scene"]
        let tableRows = rows.map { row -> [String] in
            let delta = row.deltaPct.map { String(format: "%+.0f%%", $0) } ?? "-"
            let slowestScene: String
            if let scene = row.slowestScene, let avg = row.slowestSceneAvgMs {
                slowestScene = "\(scene) (\(String(format: "%.0f", avg))ms)"
            } else {
                slowestScene = "-"
            }
            return [row.scenarioID, String(row.runs), String(format: "%.0f", row.avgDurationMs),
                    String(format: "%.0f", row.p90DurationMs), delta, slowestScene]
        }
        print(SimpleTable.render(headers: headers, rows: tableRows))
    }
}

// MARK: - insights

struct ResultsInsightsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "insights",
        abstract: "回帰・連続失敗・インフラ起因失敗・セレクタ陳腐化など注意が必要な現象を検出する")

    @OptionGroup var options: ResultsQueryOptions

    func run() throws {
        let (_, resultsDir, sinceDate) = try options.resolve()
        let records = RunResultsStore.scanRecords(resultsDir: resultsDir, since: sinceDate)
        let runs = RunResultsStore.scanRuns(resultsDir: resultsDir, since: sinceDate)
        let rows = RunResultsQuery.insights(records: records, runs: runs)

        if options.json {
            try printResultsJSON(rows)
            return
        }
        guard !rows.isEmpty else {
            print("注意が必要な現象はありません")
            return
        }
        for row in rows {
            let icon: String
            switch row.severity {
            case "critical": icon = "🔴"
            case "warn": icon = "🟡"
            default: icon = "🔵"
            }
            print("\(icon) \(row.message)")
        }
    }
}
