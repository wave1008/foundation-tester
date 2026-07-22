// run 単位で記録したホスト負荷(RunRecorder が results/runs/<YYYY-MM>/<runID>/host-metrics.ndjson
// へ 1Hz 記録した NDJSON。--project/--run で解決)、または --log 直指定の NDJSON を読み、
// 時間窓の avg/peak/min を JSON 1行で stdout に出す(ftester api host-metrics-summary)。
// 診断は stderr のみ。集計ロジックは Scripts/bench.swift の summarizeHostMetrics と同系統だが、
// ここは時間窓(--since/--until)を持つ点とスクリプト側と型を共有できない点で独立実装。

import ArgumentParser
import Foundation
import FTCore

struct ApiHostMetricsSummaryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "host-metrics-summary",
        abstract: "ホスト負荷(既定: --project/--run で run の記録を解決。--log 指定時はそのファイルを直接読む)の時間窓集計を JSON で stdout に出力する")

    @Option(name: .customLong("log"), help: "集計対象の NDJSON パスを直接指定する(省略時は --project/--run から解決)")
    var logPath: String?

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト。--log 指定時は無視)")
    var project: String?

    // プロパティ名は `run` にできない(ParsableCommand の必須メソッド run() と衝突し
    // "invalid redeclaration of 'run()'" になる)。CLI 上のフラグ名は --run のまま。
    @Option(name: .customLong("run"), help: "runID または \"latest\"(既定 latest。--log 指定時は無視)")
    var runArg = "latest"

    @Option(name: .customLong("since"),
            help: "集計開始。duration(例 10m/2h/90s/1d)または unix epoch 秒。省略時は全件")
    var since: String?

    @Option(name: .customLong("until"),
            help: "集計終了。duration(例 10m/2h/90s/1d)または unix epoch 秒。省略時は現在まで")
    var until: String?

    func run() throws {
        let sinceEpoch = try since.map(Self.parseBound)
        let untilEpoch = try until.map(Self.parseBound)

        let (resolvedLogPath, resolvedRunID) = try resolveLogPath()

        // ローテ世代(.1)が古い方なので先に読む(時系列を保つ。順序自体は集計結果に影響しないが
        // firstTs/lastTs の走査順を素直にする)
        let candidatePaths = [resolvedLogPath + ".1", resolvedLogPath]
        let existingPaths = candidatePaths.filter { FileManager.default.fileExists(atPath: $0) }
        if existingPaths.isEmpty {
            logStderr("ログファイルが見つかりません: \(resolvedLogPath)")
        }

        var samples: [[String: Any]] = []
        for path in existingPaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                logStderr("読み込みに失敗しました: \(path)")
                continue
            }
            for line in String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = String(line).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      obj["kind"] as? String == "hostMetrics",
                      let ts = obj["ts"] as? Double else { continue }
                if let sinceEpoch, ts < sinceEpoch { continue }
                if let untilEpoch, ts > untilEpoch { continue }
                samples.append(obj)
            }
        }

        let report = Self.summarize(
            samples, logPath: resolvedLogPath, runID: resolvedRunID,
            sinceEpoch: sinceEpoch, untilEpoch: untilEpoch)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        print(String(data: data, encoding: .utf8)!)
    }

    /// --log 直指定ならそのまま使う(runID は解決しない)。それ以外は --project/--run から
    /// results/runs/<YYYY-MM>/<runID>/host-metrics.ndjson を解決する。プロジェクト自体が
    /// 見つからない(タイポ等)場合は他コマンドと同様に throw で伝播させるが、run が
    /// 見つからない(results が空 / 指定 runID 不在)場合は既存の「ログファイルが見つかりません」
    /// グレースフルデグレード経路(samples:0 を返し exit 0)に合流させる
    private func resolveLogPath() throws -> (path: String, runID: String?) {
        if let logPath { return (logPath, nil) }

        let testProject = try ScenarioHost.project(named: project)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: testProject.rootURL)
        let allRuns = RunResultsStore.scanRuns(resultsDir: resultsDir)

        let meta = (runArg == "latest") ? allRuns.last : allRuns.first { $0.runID == runArg }
        guard let meta else {
            logStderr("run が見つかりません(project=\(testProject.name) run=\(runArg))")
            return ("(no run found for project=\(testProject.name) run=\(runArg))", nil)
        }

        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: meta.runID)
        return (runDir.appendingPathComponent("host-metrics.ndjson").path, meta.runID)
    }

    /// duration(数値+s/m/h/d)は `now - value*単位秒` へ、数値のみは unix epoch 秒として解釈する。
    /// どちらの形式にも合わなければ ValidationError(ArgumentParser が stderr に出して非0終了)
    static func parseBound(_ raw: String) throws -> Double {
        if let range = raw.range(of: #"^([0-9]+(?:\.[0-9]+)?)([smhd])$"#, options: .regularExpression) {
            let matched = raw[range]
            guard let value = Double(matched.dropLast()) else {
                throw ValidationError("不正な duration です: \(raw)")
            }
            let unitSeconds: Double
            switch matched.last! {
            case "s": unitSeconds = 1
            case "m": unitSeconds = 60
            case "h": unitSeconds = 3600
            case "d": unitSeconds = 86400
            default: unitSeconds = 1  // 正規表現で [smhd] に限定済みのため到達しない
            }
            return Date().timeIntervalSince1970 - value * unitSeconds
        }
        if let epoch = Double(raw) { return epoch }
        throw ValidationError(
            "--since/--until は duration(例 10m/2h/90s/1d)または unix epoch 秒で指定してください: \(raw)")
    }

    private func logStderr(_ message: String) {
        FileHandle.standardError.write(Data("[host-metrics-summary] \(message)\n".utf8))
    }

    // MARK: - 集計

    private static func summarize(
        _ samples: [[String: Any]], logPath: String, runID: String?,
        sinceEpoch: Double?, untilEpoch: Double?
    ) -> HostMetricsSummaryReport {
        var cpu: [Double] = [], gpu: [Double] = []
        var memUsed: [Int] = []
        var memTotal: Int?
        var firstTs: Double?
        var lastTs: Double?

        for obj in samples {
            guard let ts = obj["ts"] as? Double else { continue }
            firstTs = min(firstTs ?? ts, ts)
            lastTs = max(lastTs ?? ts, ts)
            if let v = obj["cpu"] as? Double { cpu.append(v) }
            if let v = obj["gpu"] as? Double { gpu.append(v) }
            if let v = obj["memUsedBytes"] as? Int { memUsed.append(v) }
            // 最後に見た値を採用(容量は稼働中不変だが、直近サンプルを正とする)
            if let v = obj["memTotalBytes"] as? Int { memTotal = v }
        }

        return HostMetricsSummaryReport(
            logPath: logPath, runID: runID, sinceEpoch: sinceEpoch, untilEpoch: untilEpoch,
            firstTs: firstTs, lastTs: lastTs,
            spanSeconds: (firstTs != nil && lastTs != nil) ? lastTs! - firstTs! : 0,
            samples: samples.count,
            cpu: doubleStat(cpu), gpu: doubleStat(gpu),
            mem: MemStat(
                avgUsedBytes: memUsed.isEmpty ? nil : Double(memUsed.reduce(0, +)) / Double(memUsed.count),
                peakUsedBytes: memUsed.max(),
                totalBytes: memTotal))
    }

    private static func doubleStat(_ values: [Double]) -> MetricStat {
        guard !values.isEmpty else { return MetricStat(avg: nil, peak: nil, min: nil, count: 0) }
        return MetricStat(
            avg: values.reduce(0, +) / Double(values.count),
            peak: values.max(), min: values.min(), count: values.count)
    }
}

// MARK: - JSON 出力

/// 省略可能なフィールドは JSON 上で null を明示する(自動合成の Encodable は Optional を
/// encodeIfPresent で「キーごと省略」してしまい null にならないため、この方針の型は全て
/// 手書き encode(to:) にする。Sources/FTCore/HostMetricsSampler.swift の HostMetricsSample と同方針)
private struct MetricStat {
    let avg: Double?
    let peak: Double?
    let min: Double?
    let count: Int
}

extension MetricStat: Encodable {
    private enum CodingKeys: String, CodingKey { case avg, peak, min, count }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(avg, forKey: .avg)
        try container.encode(peak, forKey: .peak)
        try container.encode(min, forKey: .min)
        try container.encode(count, forKey: .count)
    }
}

private struct MemStat {
    let avgUsedBytes: Double?
    let peakUsedBytes: Int?
    let totalBytes: Int?
}

extension MemStat: Encodable {
    private enum CodingKeys: String, CodingKey { case avgUsedBytes, peakUsedBytes, totalBytes }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(avgUsedBytes, forKey: .avgUsedBytes)
        try container.encode(peakUsedBytes, forKey: .peakUsedBytes)
        try container.encode(totalBytes, forKey: .totalBytes)
    }
}

private struct HostMetricsSummaryReport {
    let kind = "hostMetricsSummary"
    let logPath: String
    /// --project/--run で解決できたときのみ非 nil(--log 直指定、または run 未検出のときは nil)
    let runID: String?
    let sinceEpoch: Double?
    let untilEpoch: Double?
    let firstTs: Double?
    let lastTs: Double?
    let spanSeconds: Double
    let samples: Int
    let cpu: MetricStat
    let gpu: MetricStat
    let mem: MemStat
}

extension HostMetricsSummaryReport: Encodable {
    private enum CodingKeys: String, CodingKey {
        case kind, logPath, runID, sinceEpoch, untilEpoch, firstTs, lastTs, spanSeconds, samples
        case cpu, gpu, mem
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(logPath, forKey: .logPath)
        try container.encode(runID, forKey: .runID)
        try container.encode(sinceEpoch, forKey: .sinceEpoch)
        try container.encode(untilEpoch, forKey: .untilEpoch)
        try container.encode(firstTs, forKey: .firstTs)
        try container.encode(lastTs, forKey: .lastTs)
        try container.encode(spanSeconds, forKey: .spanSeconds)
        try container.encode(samples, forKey: .samples)
        try container.encode(cpu, forKey: .cpu)
        try container.encode(gpu, forKey: .gpu)
        try container.encode(mem, forKey: .mem)
    }
}
