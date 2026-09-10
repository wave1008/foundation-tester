// ログ・録画・レポート・デバイス添付の保持容量クリーンアップ(`fleetest clean` /
// `fleetest api clean`)。
//
// **中核は `RetentionSweeper.clean` の1箇所**で、この2コマンドはどちらも引数の解釈と
// 出力の形しか持たない —— `run` と `api run` が2実装に割れて片方だけ直る事故を繰り返さないため。
//
// **他の利用者の成果物は消さない**: 対象はこのリポジトリ配下(TestProjects/*/results,
// TestProjects/*/reports, .fleetest/*.log)と、この Mac のシミュレータの添付だけ。

import ArgumentParser
import Foundation
import FTCore

struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Delete old recordings, reports, logs and simulator attachments down to the"
            + " retention caps (see fleetest api retention)")

    @Flag(help: "List what would be deleted without deleting anything")
    var dryRun = false

    @Flag(help: "Sweep results/runs/*/*/recordings (the result JSON is never deleted)")
    var recordings = false

    @Flag(help: "Sweep TestProjects/*/reports (.md and their .png)")
    var reports = false

    @Flag(help: "Sweep .fleetest/*.log")
    var logs = false

    @Flag(name: .customLong("device-captures"),
          help: "Sweep the testmanagerd Attachments of this Mac's simulators")
    var deviceCaptures = false

    func run() async throws {
        let repoRoot = try fleetestRepoRoot()
        let report = RetentionSweeper.clean(
            repoRoot: repoRoot,
            categories: Self.categories(recordings: recordings, reports: reports, logs: logs,
                                        deviceCaptures: deviceCaptures),
            policy: LocalConfig.load().retention ?? RetentionPolicy(),
            dryRun: dryRun,
            log: { ConsoleOut.out($0) })

        for category in report.categories {
            ConsoleOut.out("\(category.category): "
                + "\(RetentionSweeper.bytesText(category.freedBytes)) from "
                + "\(category.deletedSessions)/\(category.plannedSessions) session(s), "
                + "\(RetentionSweeper.bytesText(category.keptBytes)) kept "
                + "(cap \(RetentionSweeper.bytesText(category.maxBytes)))")
        }
        ConsoleOut.out((dryRun ? "🔍 would free " : "🧹 freed ")
            + RetentionSweeper.bytesText(report.freedBytes))
    }

    /// **カテゴリ無指定は全部**(掃除は run の後に自動でも走るので、素の `fleetest clean` が
    /// 一部しか見ないと利用者の期待とずれる)
    static func categories(recordings: Bool, reports: Bool, logs: Bool,
                           deviceCaptures: Bool) -> [RetentionSweeper.Category] {
        var selected: [RetentionSweeper.Category] = []
        if deviceCaptures { selected.append(.deviceCaptures) }
        if recordings { selected.append(.recordings) }
        if reports { selected.append(.reports) }
        if logs { selected.append(.logs) }
        return selected.isEmpty ? RetentionSweeper.Category.allCases : selected
    }
}

/// 機械向け(結果 1 行の JSON だけを stdout へ。削除の進捗は stderr)
struct ApiCleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Sweep every retention category and print the result as JSON on stdout"
            + " (diagnostics on stderr only)")

    @Flag(help: "List what would be deleted without deleting anything")
    var dryRun = false

    func run() async throws {
        let report = RetentionSweeper.clean(
            repoRoot: try fleetestRepoRoot(),
            categories: RetentionSweeper.Category.allCases,
            policy: LocalConfig.load().retention ?? RetentionPolicy(),
            dryRun: dryRun,
            log: { ConsoleOut.err($0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report),
              let line = String(data: data, encoding: .utf8) else { return }
        ConsoleOut.out(line)
    }
}
