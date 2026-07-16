// RunResultsStore.swift
// ファイルベース実行結果 DB のディレクトリ配置・読み書き。
// レイアウト: <project>/results/runs/<YYYY-MM>/<runID>/run.json, scenarios/<name>.json
// (YYYY-MM は runID 先頭 8 桁 yyyyMMdd(UTC)から導出。runID の発番は RunRecorder.swift)。
// 書き込みは全て best-effort(失敗しても実行を止めない。呼び出し側は throw を想定しない)。
// 既存ファイルへの上書きは run.json の finish() 更新のみ。scenarios/ 配下は追加専用
// (2 回目以降のシナリオは RunRecorder が ~2 サフィックスで別ファイルにする)。

import Foundation

public enum RunResultsStore {

    // MARK: - パス導出

    public static func resultsDir(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent("results")
    }

    /// runID 先頭の yyyyMMdd(UTC)から YYYY-MM を導出して配置する
    public static func runDir(resultsDir: URL, runID: String) -> URL {
        let runsDir = resultsDir.appendingPathComponent("runs")
        guard runID.count >= 6 else {
            return runsDir.appendingPathComponent("unknown").appendingPathComponent(runID)
        }
        let year = runID.prefix(4)
        let monthStart = runID.index(runID.startIndex, offsetBy: 4)
        let monthEnd = runID.index(monthStart, offsetBy: 2)
        let month = runID[monthStart..<monthEnd]
        return runsDir.appendingPathComponent("\(year)-\(month)").appendingPathComponent(runID)
    }

    // MARK: - 書き込み(best-effort)

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return encoder
    }

    public static func writeMeta(_ meta: RunMetaRecord, runDir: URL) {
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        guard let data = try? makeEncoder().encode(meta) else { return }
        try? data.write(to: runDir.appendingPathComponent("run.json"), options: .atomic)
    }

    /// fileName は拡張子なし(呼び出し側が scenarioID の sanitize・連番サフィックスを付与済みの前提)
    @discardableResult
    public static func writeScenario(_ record: ScenarioRunRecord, runDir: URL, fileName: String) -> URL? {
        let dir = runDir.appendingPathComponent("scenarios")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? makeEncoder().encode(record) else { return nil }
        let url = dir.appendingPathComponent("\(fileName).json")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    // MARK: - 読み取り(スキャン)

    /// results/runs/ 配下に実在する月ディレクトリ(YYYY-MM)のうち since/until の範囲に
    /// かかるものだけを返す(文字列比較。YYYY-MM は辞書順=時系列順)。全走査回避が目的。
    private static func relevantMonthDirs(resultsDir: URL, since: Date?, until: Date?) -> [URL] {
        let runsDir = resultsDir.appendingPathComponent("runs")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runsDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        let sinceKey = since.map(monthKey)
        let untilKey = until.map(monthKey)
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { url in
                let key = url.lastPathComponent
                if let sinceKey, key < sinceKey { return false }
                if let untilKey, key > untilKey { return false }
                return true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func monthKey(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    private static func runDirs(in monthDir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: monthDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func warnSkipped(_ count: Int, kind: String) {
        guard count > 0 else { return }
        let message = "RunResultsStore: \(count) 件の\(kind)をスキップしました" +
            "(壊れている、または schemaVersion が新しすぎます)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    /// since/until は startedAt(ISO8601)でフィルタ。両方 nil なら全件
    public static func scanRuns(resultsDir: URL, since: Date? = nil, until: Date? = nil) -> [RunMetaRecord] {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        var results: [RunMetaRecord] = []
        var skipped = 0
        for monthDir in relevantMonthDirs(resultsDir: resultsDir, since: since, until: until) {
            for runDir in runDirs(in: monthDir) {
                let metaURL = runDir.appendingPathComponent("run.json")
                guard let data = try? Data(contentsOf: metaURL),
                      let meta = try? decoder.decode(RunMetaRecord.self, from: data) else {
                    skipped += 1
                    continue
                }
                guard meta.schemaVersion <= RunRecordSchema.current else {
                    skipped += 1
                    continue
                }
                if let since, let started = formatter.date(from: meta.startedAt), started < since {
                    continue
                }
                if let until, let started = formatter.date(from: meta.startedAt), started > until {
                    continue
                }
                results.append(meta)
            }
        }
        warnSkipped(skipped, kind: "run.json")
        return results.sorted { $0.runID < $1.runID }
    }

    public static func scanRecords(resultsDir: URL, since: Date? = nil, until: Date? = nil) -> [ScenarioRunRecord] {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        var results: [ScenarioRunRecord] = []
        var skipped = 0
        for monthDir in relevantMonthDirs(resultsDir: resultsDir, since: since, until: until) {
            for runDir in runDirs(in: monthDir) {
                let scenariosDir = runDir.appendingPathComponent("scenarios")
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: scenariosDir, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]) else {
                    continue
                }
                for file in files where file.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: file),
                          let record = try? decoder.decode(ScenarioRunRecord.self, from: data) else {
                        skipped += 1
                        continue
                    }
                    guard record.schemaVersion <= RunRecordSchema.current else {
                        skipped += 1
                        continue
                    }
                    if let since, let started = formatter.date(from: record.startedAt), started < since {
                        continue
                    }
                    if let until, let started = formatter.date(from: record.startedAt), started > until {
                        continue
                    }
                    results.append(record)
                }
            }
        }
        warnSkipped(skipped, kind: "scenario record")
        return results.sorted { $0.runID == $1.runID ? $0.scenarioID < $1.scenarioID : $0.runID < $1.runID }
    }
}
