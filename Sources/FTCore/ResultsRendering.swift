// ResultsRendering.swift
// `fleetest results <list|summary|flaky|trend|devices|slow|insights>` の人間可読出力。
// **CLI(ResultsCommand)と MCP(ft_results)が同じ関数を呼ぶ**(表の列・見出し・空のときの文言を2つ持たない)。
// 集計そのものは RunResultsQuery。ここは行 → 文字列だけ。戻り値に末尾の改行は付けない。

import Foundation

/// startedAt(ISO8601 UTC)をローカルタイムゾーンの表示にする。パース不能ならそのまま返す
public func formatLocal(_ iso8601: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso8601) else { return iso8601 }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: date)
}

/// 日本語混じりでも桁数(character count)基準で揃える簡易テーブル(半角想定・厳密な幅計算はしない)
public enum SimpleTable {
    public static func render(headers: [String], rows: [[String]]) -> String {
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

public enum ResultsRendering {

    /// CLI(`--since`/`--limit`/`--min-runs`)と MCP が同じ既定を引く唯一の置き場
    public static let defaultSince = "90d"
    public static let defaultListLimit = 20
    public static let defaultSlowLimit = 10
    public static let defaultMinRuns = 5

    public static func list(_ rows: [RunMetaRecord]) -> String {
        guard !rows.isEmpty else { return "No matching runs" }
        let headers = ["runID", "time", "trigger", "profile", "machine", "passed/failed/total"]
        let tableRows = rows.map { meta -> [String] in
            let counts: String
            if let total = meta.total, let passed = meta.passed, let failed = meta.failed {
                counts = "\(passed)/\(failed)/\(total)"
            } else {
                counts = "(incomplete)"
            }
            return [meta.runID, formatLocal(meta.startedAt), meta.trigger,
                    meta.profile ?? "-", meta.host, counts]
        }
        return SimpleTable.render(headers: headers, rows: tableRows)
    }

    public static func summary(_ rows: [RunResultsQuery.ScenarioSummaryRow]) -> String {
        guard !rows.isEmpty else { return "No matching scenarios" }
        let headers = ["scenario", "runs", "pass rate", "avg ms", "median ms", "last run", "last result"]
        let tableRows = rows.map { row -> [String] in
            [row.scenarioID, String(row.runs), String(format: "%.1f%%", row.successRate),
             row.avgDurationMs.map { String(format: "%.0f", $0) } ?? "-",
             row.medianDurationMs.map { String(format: "%.0f", $0) } ?? "-",
             row.lastRunAt.map(formatLocal) ?? "-",
             row.lastPassed.map { $0 ? "✅" : "❌" } ?? "-"]
        }
        return SimpleTable.render(headers: headers, rows: tableRows)
    }

    /// `minRunsOption`: 空のときの文言が名指しする引数名(CLI は `--min-runs`、MCP は `minRuns`)
    public static func flaky(_ rows: [RunResultsQuery.FlakyRow], minRuns: Int,
                             minRunsOption: String = "--min-runs") -> String {
        guard !rows.isEmpty else {
            return "No flaky scenarios (candidates need \(minRunsOption) \(minRuns)+ and mixed pass/fail)"
        }
        let headers = ["scenario", "runs", "fail rate", "flip score", "recent results (new→old)"]
        let tableRows = rows.map { row -> [String] in
            [row.scenarioID, String(row.runs), String(format: "%.1f%%", row.failureRate),
             String(format: "%.2f", row.flakinessScore),
             row.recentResults.map { $0 ? "✅" : "❌" }.joined()]
        }
        return SimpleTable.render(headers: headers, rows: tableRows)
    }

    public static func trend(_ rows: [ScenarioRunRecord], scenario: String) -> String {
        guard !rows.isEmpty else { return "No run history for: \(scenario)" }
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
                    String(record.durationMs), record.worker ?? "-", record.host, bar]
        }
        return SimpleTable.render(headers: headers, rows: tableRows)
    }

    public static func devices(_ report: RunResultsQuery.DevicesReport) -> String {
        guard !report.byWorker.isEmpty else { return "No matching runs" }
        let perWorker = SimpleTable.render(
            headers: ["worker", "runs", "pass rate", "avg ms"],
            rows: report.byWorker.map { row in
                [row.worker, String(row.runs), String(format: "%.1f%%", row.successRate),
                 row.avgDurationMs.map { String(format: "%.0f", $0) } ?? "-"]
            })
        let perPlatform = SimpleTable.render(
            headers: ["platform", "runs", "pass rate", "avg ms"],
            rows: report.byPlatform.map { row in
                [row.platform, String(row.runs), String(format: "%.1f%%", row.successRate),
                 row.avgDurationMs.map { String(format: "%.0f", $0) } ?? "-"]
            })
        return "[per worker]\n\(perWorker)\n\n[per platform]\n\(perPlatform)"
    }

    public static func slow(_ rows: [RunResultsQuery.SlowTestRow]) -> String {
        guard !rows.isEmpty else { return "No matching scenarios" }
        // 同じ scenarioID を複数 platform で回すプロジェクトでは1シナリオが複数行に分かれる
        // (slowTests は (scenarioID, platform) で束ねる)ので platform 欄を出す
        let headers = ["scenario", "platform", "runs", "avg ms", "p90 ms", "regression", "slowest scene"]
        let tableRows = rows.map { row -> [String] in
            let delta = row.deltaPct.map { String(format: "%+.0f%%", $0) } ?? "-"
            let slowestScene: String
            if let scene = row.slowestScene, let avg = row.slowestSceneAvgMs {
                slowestScene = "\(scene) (\(String(format: "%.0f", avg))ms)"
            } else {
                slowestScene = "-"
            }
            return [row.scenarioID, row.platform, String(row.runs), String(format: "%.0f", row.avgDurationMs),
                    String(format: "%.0f", row.p90DurationMs), delta, slowestScene]
        }
        return SimpleTable.render(headers: headers, rows: tableRows)
    }

    public static func insights(_ rows: [RunResultsQuery.InsightRow]) -> String {
        guard !rows.isEmpty else { return "Nothing needs attention" }
        return rows.map { row -> String in
            let icon: String
            switch row.severity {
            case "critical": icon = "🔴"
            case "warn": icon = "🟡"
            default: icon = "🔵"
            }
            return "\(icon) \(row.message)"
        }.joined(separator: "\n")
    }
}
