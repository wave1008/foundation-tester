// ログ・録画・レポート・デバイス添付の保持容量クリーンアップ(`fleetest clean` /
// `fleetest api clean`)。
//
// **中核は `RetentionSweeper.clean` の1箇所**で、この2コマンドはどちらも引数の解釈と
// 出力の形しか持たない —— `run` と `api run` が2実装に割れて片方だけ直る事故を繰り返さないため。
//
// **他の利用者の成果物は消さない**: 対象はこのリポジトリ配下(TestProjects/*/results,
// TestProjects/*/reports, .fleetest/*.log)と、この Mac のシミュレータの添付だけ。
//
// **消す処理は機械で同時に1本**(`RetentionSweepLock`)。背景の自動掃除は先客がいれば黙って抜け、
// 手動(`clean` / `api clean`)は先客を名指しして失敗する。dry-run は錠を取らない(消さない)。

import ArgumentParser
import Foundation
import FTCore

struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Delete old recordings, reports, logs and simulator attachments: any category"
            + " above 90% of its limit is swept back down to 90% (limits: fleetest api retention)")

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

    /// run の完了時に `RunCompletionSweep` が起こす背景の掃除(利用者は打たない)
    @Flag(name: .customLong("background"), help: .hidden)
    var background = false

    /// 背景の掃除が保護する run(たった今終わった run の runID)
    @Option(name: .customLong("active-run-id"), help: .hidden)
    var activeRunID: String?

    func run() async throws {
        let roots = try RetentionSweeper.Roots.resolve()
        if background {
            RunCompletionSweep.runInBackground(roots: roots, activeRunID: activeRunID)
            return
        }
        // 錠は消す処理だけが取る。**変数に束縛して run の終わりまで保持する**(捨てると即座に閉じて外れる)
        let lock = dryRun ? nil : try Self.acquireLockOrExplain()
        defer { withExtendedLifetime(lock) {} }
        let report = RetentionSweeper.clean(
            roots: roots,
            categories: Self.categories(recordings: recordings, reports: reports, logs: logs,
                                        deviceCaptures: deviceCaptures),
            policy: LocalConfig.load().retention ?? RetentionPolicy(),
            dryRun: dryRun,
            log: { ConsoleOut.out($0) }, notice: { ConsoleOut.out($0) })

        for category in report.categories {
            ConsoleOut.out("\(category.category): "
                + "\(RetentionSweeper.bytesText(category.freedBytes)) from "
                + "\(category.deletedSessions)/\(category.plannedSessions) session(s), "
                + "\(RetentionSweeper.bytesText(category.keptBytes)) kept "
                + "(limit \(RetentionSweeper.bytesText(category.maxBytes)); sweeps above "
                + "\(RetentionSweeper.bytesText(category.sweepLineBytes)))")
        }
        ConsoleOut.out((dryRun ? "🔍 would free " : "🧹 freed ")
            + RetentionSweeper.bytesText(report.freedBytes))
    }

    /// 手動の掃除の錠。取れなければ先客を名指しして失敗する(背景の掃除と同時に消さない)。
    /// 文言は**拡張がそのまま画面に出す**(`api clean` の非ゼロ終了は stderr の末尾が理由になる)
    static func acquireLockOrExplain() throws -> FileHandle {
        if let lock = RetentionSweepLock.tryAcquire() { return lock }
        let holder = RetentionSweepLock.holderPID().map { " (pid \($0))" } ?? ""
        throw CleanupBusyError(message: "Another cleanup is already running\(holder) — usually the"
            + " background cleanup a finished run started. Try again after it ends.")
    }

    /// **カテゴリ無指定は全部**(掃除は run の開始時に自動でも走るので、素の `fleetest clean` が
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
        let lock = dryRun ? nil : try CleanCommand.acquireLockOrExplain()
        defer { withExtendedLifetime(lock) {} }
        let report = RetentionSweeper.clean(
            roots: try RetentionSweeper.Roots.resolve(),
            categories: RetentionSweeper.Category.allCases,
            policy: LocalConfig.load().retention ?? RetentionPolicy(),
            dryRun: dryRun,
            log: { ConsoleOut.err($0) }, notice: { ConsoleOut.err($0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report),
              let line = String(data: data, encoding: .utf8) else { return }
        ConsoleOut.out(line)
    }
}

/// **`ValidationError` にしない** —— あれは使い方の誤りとして使い方の表示を後ろに付け、終了コード 64 に
/// なる。拡張は stderr の末尾を理由として画面に出すので、使い方の表示が理由を押し流す
private struct CleanupBusyError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
