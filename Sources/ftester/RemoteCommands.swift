// RemoteCommands.swift
// `ftester remote status` / `ftester remote clean` (docs/remote-runner.md §16.4・§16.5)。
// フリート運用の診断・掃除。純粋ロジックは Sources/FTCore/RemoteDispatch.swift 側
// (RemoteStatusProbe/RemoteCleanPlan、単体テスト対象)。ssh の張り方は
// Sources/ftester/RemoteRunDispatcher.swift と同じ規律(BatchMode=yes・ConnectTimeout=10)だが
// そちらは private のため複製する。

import ArgumentParser
import FTBridgeClient
import FTCore
import Foundation

/// 全 ssh 共通の基底引数。ConnectTimeout が無いと到達不能ホストで TCP 既定(75秒超)固まる
/// (RemoteRunDispatcher.sshBase と同じ規律)
private let remoteSSHBase = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]

struct RemoteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote",
        abstract: "Fleet operations for --host dispatch: diagnose and clean up remote runners (docs/remote-runner.md §16.4/§16.5)",
        subcommands: [Status.self, Clean.self])

    // MARK: - status

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show reachability, login state, git revision, toolchain, and free disk space for a fleet of remote hosts (docs/remote-runner.md §16.5)")

        @Option(name: .customLong("host"), parsing: .upToNextOption,
                help: "Remote host to check (user@host or host). Repeatable. A host registry is planned (docs/remote-runner.md §13); until then this is required")
        var hosts: [String] = []

        @Option(name: .customLong("remote-dir"),
                help: "Runner-only base directory on the remote host (default: ~/ftester-runner)")
        var remoteDir: String = "~/ftester-runner"

        @Flag(help: "Also probe Foundation Models availability on each host (runs `<binary> doctor --fm-only`; adds a few seconds per host, so it is off by default)")
        var fm = false

        @Flag(help: "Emit one JSON object instead of a table")
        var json = false

        func run() async throws {
            guard !hosts.isEmpty else {
                throw ValidationError(
                    "no hosts specified (pass --host <user@host>; a host registry is planned in docs/remote-runner.md §13)")
            }
            // status は $HOME をリモートで展開させるため二重引用符でパスを包む。入口で文字種を
            // 絞らないと `$(…)` がリモートで実行される
            try RemoteLayout.validateBase(remoteDir)
            let targets = hosts
            let remoteDirRaw = remoteDir
            let wantFM = fm
            let localRevision = localGitRevision()
            let localToolchain = ToolchainFingerprint.current()

            let rows: [HostRow] = await withTaskGroup(of: (Int, HostRow).self) { group in
                for (index, raw) in targets.enumerated() {
                    group.addTask {
                        (index, await Self.probe(raw, remoteDirRaw: remoteDirRaw, wantFM: wantFM))
                    }
                }
                var collected: [Int: HostRow] = [:]
                for await (index, row) in group { collected[index] = row }
                return targets.indices.compactMap { collected[$0] }
            }

            let reports = rows.map { row in
                HostReport(row: row, localRevision: localRevision, localToolchain: localToolchain)
            }

            if json {
                emitJSON(reports)
            } else {
                emitTable(reports)
                for r in reports where !r.reachable {
                    print("\(r.sshTarget): \(r.detail ?? "unreachable")")
                }
            }
            if reports.contains(where: { !$0.reachable || !$0.compatible }) {
                throw ExitCode(1)
            }
        }

        /// 1ホスト分の到達性・rev・toolchain・binary・空き容量をまとめて取る(ssh 1回)。
        /// layout.base はここでは $HOME を未解決のまま埋め込んだ式になり得る
        /// (RemoteLayout.resolveBase(raw, home: "$HOME") — remote status は全ホスト並列・
        /// 1 ssh 呼び出しに収める設計のため、$HOME 解決だけの往復を別に持たない。
        /// リモートシェルが実行時に自分の $HOME で展開する。RemoteStatusProbe.command が
        /// 二重引用符で包むのはこのため)
        private static func probe(_ raw: String, remoteDirRaw: String, wantFM: Bool) async -> HostRow {
            guard let hostSpec = try? RemoteHostSpec.parse(raw) else {
                return HostRow(sshTarget: raw, reachable: false,
                               detail: "invalid --host value: \(raw)", status: nil, fmOK: nil)
            }
            let target = hostSpec.sshTarget
            let layout = RemoteLayout(base: RemoteLayout.resolveBase(remoteDirRaw, home: "$HOME"))
            let command = RemoteStatusProbe.command(layout: layout)
            do {
                let result = try Shell.run(remoteSSHBase + [target, command])
                // ssh は自身の接続失敗(DNS/認証/タイムアウト等)だけ 255 を返す規約 — リモート
                // コマンドの終了コードはそのまま通るため、df 等が失敗しても到達はしている
                guard result.status != 255 else {
                    return HostRow(sshTarget: target, reachable: false,
                                   detail: "ssh connection failed (status 255)\n\(result.tail)",
                                   status: nil, fmOK: nil)
                }
                let status = RemoteStatusProbe.parse(result.output)
                let fmOK = wantFM ? await probeFM(target: target, layout: layout) : nil
                return HostRow(sshTarget: target, reachable: true, detail: nil, status: status, fmOK: fmOK)
            } catch {
                return HostRow(sshTarget: target, reachable: false,
                               detail: "\(error)", status: nil, fmOK: nil)
            }
        }

        private static func probeFM(target: String, layout: RemoteLayout) async -> Bool? {
            let binary = RemoteStatusProbe.dquote(layout.binary)
            guard let result = try? Shell.run(remoteSSHBase + [target, "\(binary) doctor --fm-only"]) else {
                return nil
            }
            return result.status == 0
        }

        private func emitTable(_ reports: [HostReport]) {
            let header = ["HOST", "REACHABLE", "LOGIN", "REV", "TOOLCHAIN", "FM", "BINARY", "FREE"]
            var rows = [header]
            rows.append(contentsOf: reports.map(cells))
            let widths = (0..<header.count).map { col in rows.map { $0[col].count }.max() ?? 0 }
            for row in rows {
                let line = zip(row, widths)
                    .map { text, width in text + String(repeating: " ", count: max(0, width - text.count)) }
                    .joined(separator: "  ")
                print(line)
            }
        }

        private func cells(_ r: HostReport) -> [String] {
            guard r.reachable else {
                return [r.sshTarget, "no", "-", "-", "-", "-", "-", "-"]
            }
            let login: String
            if let session = r.status?.session {
                login = session.isLoggedIn ? "yes" : "no (console: \(session.consoleUser))"
            } else {
                login = "-"
            }
            let fm = r.fmOK.map { $0 ? "ok" : "ng" } ?? "-"
            let binary = r.status.map { $0.binaryPresent ? "yes" : "no" } ?? "-"
            let free = r.status?.freeKB.map(formatFreeSpace) ?? "-"
            return [r.sshTarget, "yes", login,
                    mark(r, label: "git revision", value: r.status?.revision),
                    mark(r, label: "toolchain", value: r.status?.toolchain),
                    fm, binary, free]
        }

        private func mark(_ r: HostReport, label: String, value: String?) -> String {
            let icon = r.mismatchReasons.contains(where: { $0.hasPrefix(label) }) ? "⚠️" : "✅"
            return "\(icon) \(value ?? "?")"
        }

        private func emitJSON(_ reports: [HostReport]) {
            let hosts = reports.map { r in
                StatusHostJSON(
                    host: r.sshTarget,
                    reachable: r.reachable,
                    loggedIn: r.status?.session?.isLoggedIn,
                    consoleUser: r.status?.session?.consoleUser,
                    revision: r.status?.revision,
                    revisionCompatible: r.reachable
                        ? !r.mismatchReasons.contains(where: { $0.hasPrefix("git revision") }) : nil,
                    toolchain: r.status?.toolchain,
                    toolchainCompatible: r.reachable
                        ? !r.mismatchReasons.contains(where: { $0.hasPrefix("toolchain") }) : nil,
                    fm: r.fmOK,
                    binaryPresent: r.status?.binaryPresent,
                    freeKB: r.status?.freeKB,
                    error: r.detail)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(StatusJSON(hosts: hosts)),
                  let line = String(data: data, encoding: .utf8) else { return }
            print(line)
        }
    }

    // MARK: - clean

    struct Clean: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clean",
            abstract: "Stop orphaned bridges/simulators and delete results, reports, and dispatch leftovers older than --keep-days on remote hosts (docs/remote-runner.md §16.4)")

        @Option(name: .customLong("host"), parsing: .upToNextOption,
                help: "Remote host to clean (user@host or host). Repeatable, required")
        var hosts: [String] = []

        @Option(name: .customLong("remote-dir"),
                help: "Runner-only base directory on the remote host (default: ~/ftester-runner)")
        var remoteDir: String = "~/ftester-runner"

        @Option(name: .customLong("keep-days"), help: "Delete results/reports/dispatch entries older than this many days")
        var keepDays: Int = 7

        @Flag(name: .customLong("dry-run"), help: "List what would be deleted instead of deleting it")
        var dryRun = false

        func run() async throws {
            guard !hosts.isEmpty else {
                throw ValidationError(
                    "no hosts specified (pass --host <user@host>; a host registry is planned in docs/remote-runner.md §13)")
            }
            try RemoteLayout.validateBase(remoteDir)
            if !dryRun {
                print("This permanently deletes files older than \(keepDays) day(s) on each host below."
                    + " Pass --dry-run first to preview what would be removed.")
            }
            var failures = 0
            // 破壊的操作なので並列にしない(1台ずつ結果を見せる。docs/remote-runner.md §16.4)
            for raw in hosts {
                print("== \(raw) ==")
                do {
                    try cleanOne(raw)
                } catch {
                    print("error: \(error.localizedDescription)")
                    failures += 1
                }
            }
            if failures > 0 { throw ExitCode(1) }
        }

        private func cleanOne(_ raw: String) throws {
            let hostSpec = try RemoteHostSpec.parse(raw)
            let target = hostSpec.sshTarget
            let layout = try Self.resolveLayout(target: target, remoteDirRaw: remoteDir)

            print("→ stopping bridges and shutting down simulators/emulators")
            let devicesDownCommand = RemoteShell.remoteRunCommand(
                layout: layout, ftesterArgs: ["devices", "down"], sessionMode: "direct")
            let downResult = try Shell.run(remoteSSHBase + [target, devicesDownCommand])
            if downResult.status != 0 {
                print("warning: `devices down` exited with status \(downResult.status)\n\(downResult.tail)")
            }

            var totalEntries = 0
            for command in RemoteCleanPlan.commands(layout: layout, keepDays: keepDays, dryRun: true) {
                let result = try Shell.run(remoteSSHBase + [target, command])
                totalEntries += result.output.split(separator: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            }
            print(dryRun
                ? "→ \(totalEntries) entr\(totalEntries == 1 ? "y" : "ies") older than \(keepDays) day(s) (not deleted; --dry-run)"
                : "→ deleting \(totalEntries) entr\(totalEntries == 1 ? "y" : "ies") older than \(keepDays) day(s)")

            if !dryRun {
                for command in RemoteCleanPlan.commands(layout: layout, keepDays: keepDays, dryRun: false) {
                    let result = try Shell.run(remoteSSHBase + [target, command])
                    if result.status != 0 {
                        print("warning: cleanup command exited with status \(result.status): \(command)\n\(result.tail)")
                    }
                }
            }

            if let dfResult = try? Shell.run(remoteSSHBase + [target, "df -k \(RemoteShell.quote(layout.base)) | tail -1"]),
               let freeKB = RemoteStatusProbe.parseFreeKB(dfResult.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                print("→ free space: \(formatFreeSpace(freeKB))")
            }
        }

        /// `<remote-dir>` の $HOME を実際に取得して絶対パスへ解決する(RemoteRunDispatcher.resolveLayout
        /// と同じ規律だが private のため複製・簡略化。clean は1台ずつ順に実行するため remote status
        /// と違い「1 ssh に収める」制約が無く、通常どおり事前解決してから RemoteShell.quote できる)
        private static func resolveLayout(target: String, remoteDirRaw: String) throws -> RemoteLayout {
            // 実行時の失敗は ValidationError にしない — ArgumentParser の ValidationError は
            // LocalizedError を実装しておらず、catch 側の localizedDescription が
            // "The operation couldn't be completed" に化けて原因が消える(実測)
            let result = try Shell.run(remoteSSHBase + [target, "echo $HOME"])
            guard result.status == 0 else {
                throw RemoteDispatchError.remoteSetupFailed(
                    "cannot reach \(target) over ssh (status \(result.status))\n\(result.tail)")
            }
            let home = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !home.isEmpty else {
                throw RemoteDispatchError.remoteSetupFailed("could not determine $HOME on \(target)")
            }
            return RemoteLayout(base: RemoteLayout.resolveBase(remoteDirRaw, home: home))
        }
    }
}

// MARK: - shared helpers

/// remote status の1ホスト分の生行(mismatch 判定前)。Sendable なのはタスクグループの
/// 境界を越えて返すため
private struct HostRow: Sendable {
    let sshTarget: String
    let reachable: Bool
    let detail: String?
    let status: RemoteHostStatus?
    let fmOK: Bool?
}

/// HostRow にローカル値との適合判定を添えたもの(表示直前に1回だけ計算する。
/// タスクグループはローカル値を必要としないため HostRow には含めない)
private struct HostReport {
    let sshTarget: String
    let reachable: Bool
    let detail: String?
    let status: RemoteHostStatus?
    let fmOK: Bool?
    let mismatchReasons: [String]

    init(row: HostRow, localRevision: String?, localToolchain: String?) {
        sshTarget = row.sshTarget
        reachable = row.reachable
        detail = row.detail
        status = row.status
        fmOK = row.fmOK
        mismatchReasons = row.status.map {
            RemoteCompat.mismatches(localRevision: localRevision, remoteRevision: $0.revision,
                                    localToolchain: localToolchain, remoteToolchain: $0.toolchain)
        } ?? []
    }

    var compatible: Bool { reachable && status != nil && mismatchReasons.isEmpty }
}

private struct StatusHostJSON: Encodable {
    let host: String
    let reachable: Bool
    let loggedIn: Bool?
    let consoleUser: String?
    let revision: String?
    let revisionCompatible: Bool?
    let toolchain: String?
    let toolchainCompatible: Bool?
    let fm: Bool?
    let binaryPresent: Bool?
    let freeKB: Int?
    let error: String?
}

private struct StatusJSON: Encodable {
    let hosts: [StatusHostJSON]
}

private func localGitRevision() -> String? {
    guard let root = try? RepoRoot.find(),
          let result = try? Shell.run(["git", "-C", root.path, "rev-parse", "HEAD"]),
          result.status == 0 else { return nil }
    let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return output.isEmpty ? nil : output
}

private func formatFreeSpace(_ kb: Int) -> String {
    String(format: "%.1f GB", Double(kb) / 1024 / 1024)
}
