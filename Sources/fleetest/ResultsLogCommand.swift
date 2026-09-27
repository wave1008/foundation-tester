// ResultsLogCommand.swift
// 1 run のシナリオごとの実行ログ(RunRecorder が書く
// results/runs/<YYYY-MM>/<runID>/events/<fileBase>.ndjson。fileBase は同じ run の
// scenarios/<fileBase>.json と対応)を人間可読に整形して表示する(fleetest results log)。
// 整形は FTCore.EventLogFormat の1箇所(MCP 等の別の呼び手ができてもここで整形し直さない)。

import ArgumentParser
import Foundation
import FTCore

struct ResultsLogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Print a run's per-scenario execution log (events/*.ndjson), one heading per scenario")

    @Argument(help: "The runID to look up, or \"latest\"")
    var runID: String

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Only show the log for this scenario ID")
    var scenario: String?

    @Flag(help: "Print the raw NDJSON lines instead of formatting them")
    var raw = false

    func run() throws {
        let testProject = try ScenarioHost.project(named: project)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: testProject.rootURL)

        let resolvedRunID: String
        if runID == "latest" {
            guard let latest = RunResultsStore.scanRuns(resultsDir: resultsDir).last else {
                ConsoleOut.err("no runs found for project: \(testProject.name)")
                throw ExitCode(1)
            }
            resolvedRunID = latest.runID
        } else {
            resolvedRunID = runID
        }

        let runDir = RunResultsStore.runDir(resultsDir: resultsDir, runID: resolvedRunID)
        guard RunResultsStore.meta(runDir: runDir) != nil else {
            ConsoleOut.err("run not found: \(resolvedRunID)")
            throw ExitCode(1)
        }

        let eventsDir = runDir.appendingPathComponent("events")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: eventsDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // 無い理由は2つ考えられ、どちらも同じ「もう読めない」という事実は変わらない ——
            // ①この機能より前に走った run ②retention sweep が上限超過で events/ ごと削除した
            // (RetentionSweeper.eventLogSessions)。区別できないので理由は決め打たない
            ConsoleOut.err("this run has no execution log (events/ is missing — either the run predates"
                + " this feature, or it was cleaned up by retention): \(resolvedRunID)")
            throw ExitCode(1)
        }

        let entries = ResultsLogEntries.collect(runDir: runDir, eventsDir: eventsDir, scenarioFilter: scenario)
        guard !entries.isEmpty else {
            ConsoleOut.err(scenario != nil ? "No log entries for scenario: \(scenario!)" : "No log entries")
            throw ExitCode(1)
        }

        for (offset, entry) in entries.enumerated() {
            // --raw の stdout は NDJSON だけにする(jq 等へ流せるように)。見出しは stderr へ
            if raw {
                ConsoleOut.err("=== \(entry.heading) ===")
            } else {
                if offset > 0 { ConsoleOut.out("") }
                ConsoleOut.out("=== \(entry.heading) ===")
            }
            guard let text = try? String(contentsOf: entry.fileURL, encoding: .utf8) else {
                ConsoleOut.err("failed to read: \(entry.fileURL.path)")
                continue
            }
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if raw {
                    ConsoleOut.out(String(rawLine))
                } else {
                    for formatted in EventLogFormat.format(String(rawLine)) {
                        ConsoleOut.out(formatted)
                    }
                }
            }
        }
    }
}

/// events/ 配下のファイルを表示順(scenarios/ の順 → superseded → incomplete)に並べる。
/// デバイス非依存の純粋なファイル走査なので `ResultsLogEntriesTests` から直接検証できる
enum ResultsLogEntries {
    struct Entry {
        let heading: String
        let fileURL: URL
    }

    static func collect(runDir: URL, eventsDir: URL, scenarioFilter: String?) -> [Entry] {
        var entries: [Entry] = []
        entries += completedEntries(runDir: runDir, eventsDir: eventsDir, scenarioFilter: scenarioFilter)
        entries += supersededEntries(eventsDir: eventsDir, scenarioFilter: scenarioFilter)
        entries += inflightEntries(eventsDir: eventsDir, scenarioFilter: scenarioFilter)
        return entries
    }

    // MARK: - 完走したシナリオ(scenarios/*.json と対応する events/<fileBase>.ndjson)

    private static func completedEntries(runDir: URL, eventsDir: URL, scenarioFilter: String?) -> [Entry] {
        let scenariosDir = runDir.appendingPathComponent("scenarios")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: scenariosDir.path) else {
            return []
        }
        let decoder = JSONDecoder()
        var result: [Entry] = []
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let fileBase = String(name.dropLast(".json".count))
            guard let data = try? Data(contentsOf: scenariosDir.appendingPathComponent(name)),
                  let record = try? decoder.decode(ScenarioRunRecord.self, from: data) else { continue }
            if let scenarioFilter, record.scenarioID != scenarioFilter { continue }
            let eventsURL = eventsDir.appendingPathComponent("\(fileBase).ndjson")
            guard FileManager.default.fileExists(atPath: eventsURL.path) else { continue }
            let worker = record.worker.map { " (worker: \($0))" } ?? ""
            result.append(Entry(heading: "\(record.scenarioID)\(worker)", fileURL: eventsURL))
        }
        return result
    }

    // MARK: - 振り直しで退避された記録

    private static func supersededEntries(eventsDir: URL, scenarioFilter: String?) -> [Entry] {
        let dir = eventsDir.appendingPathComponent("superseded")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let sanitizedFilter = scenarioFilter.map(sanitizeFileName)
        var result: [Entry] = []
        for name in names.filter({ $0.hasSuffix(".ndjson") }).sorted() {
            let withoutExt = String(name.dropLast(".ndjson".count))
            if let sanitizedFilter, sanitizedScenarioID(fromSupersededBase: withoutExt) != sanitizedFilter {
                continue
            }
            result.append(Entry(heading: "\(withoutExt) (superseded)", fileURL: dir.appendingPathComponent(name)))
        }
        return result
    }

    /// `<fileBase>.<k>.ndjson` の `<fileBase>` を取り出す(拡張子を落とした文字列から)。
    /// `<fileBase>` 自体は `sanitizeFileName(scenarioID)` に "~N" の連番サフィックスが付きうる
    /// (RunRecorder.fileName)ので、末尾の ".<k>" と "~N" の両方を剥がして比べる。
    /// k が数字でない(想定外の名前)ときは nil を返し、--scenario には当たらない側へ倒す
    private static func sanitizedScenarioID(fromSupersededBase withoutExt: String) -> String? {
        guard let lastDot = withoutExt.lastIndex(of: "."),
              !withoutExt[withoutExt.index(after: lastDot)...].isEmpty,
              withoutExt[withoutExt.index(after: lastDot)...].allSatisfy(\.isNumber) else { return nil }
        var fileBase = String(withoutExt[..<lastDot])
        if let tilde = fileBase.lastIndex(of: "~"),
           fileBase[fileBase.index(after: tilde)...].allSatisfy(\.isNumber) {
            fileBase = String(fileBase[..<tilde])
        }
        return fileBase
    }

    // MARK: - 書き込み中/kill されて残ったもの

    private static func inflightEntries(eventsDir: URL, scenarioFilter: String?) -> [Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: eventsDir.path) else { return [] }
        var result: [Entry] = []
        for name in names.filter({ $0.hasPrefix(".inflight-") && $0.hasSuffix(".ndjson") }).sorted() {
            let fileURL = eventsDir.appendingPathComponent(name)
            let discoveredScenario = firstScenarioID(in: fileURL)
            if let scenarioFilter {
                guard discoveredScenario == scenarioFilter else { continue }
            }
            let label = discoveredScenario ?? name
            result.append(Entry(heading: "\(label) (incomplete)", fileURL: fileURL))
        }
        return result
    }

    /// .inflight ファイルはどのシナリオか名前からは分からない —— 中の最初の event 行の
    /// `scenario` 欄から分かる場合がある。見つからなければ nil(推測しない)
    private static func firstScenarioID(in fileURL: URL) -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = envelope["event"] as? [String: Any],
                  let scenario = event["scenario"] as? String else { continue }
            return scenario
        }
        return nil
    }

    /// **契約は `RunRecorder.sanitizeFileName` と同一** —— 片方だけ変えると superseded の
    /// --scenario 絞り込みが静かに外れる
    private static func sanitizeFileName(_ scenarioID: String) -> String {
        String(scenarioID.map { $0 == "/" || $0 == ":" ? "_" : $0 })
    }
}
