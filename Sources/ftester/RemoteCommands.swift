// RemoteCommands.swift
// `ftester remote status` / `ftester remote clean` (docs/remote-runner.md §16.4・§16.5)。
// フリート運用の診断・掃除。純粋ロジックは Sources/FTCore/RemoteDispatch.swift 側
// (RemoteStatusProbe/RemoteCleanPlan、単体テスト対象)。ssh の張り方は
// Sources/ftester/RemoteRunDispatcher.swift と同じ規律(BatchMode=yes・ConnectTimeout=10)だが
// そちらは private のため複製する。
// `remote setup` / `remote exec` は Sources/ftester/RemoteSetupCommand.swift(RemoteCommand の
// extension として Setup/Exec を定義。ここではサブコマンド一覧への登録だけ行う)。
// `remote hosts` (list/add/remove) はここで定義する。登録簿(名前→ssh 実体)は
// LocalConfig.remoteHosts に置く(docs/remote-runner.md §13・§15.2)。`--host` を受ける
// 全コマンド(run/api run/remote status・clean・setup・exec)は RemoteHostResolver.resolve を
// 通す(個別に登録簿を読む実装を増やさない)。

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
        abstract: "Fleet operations for --host dispatch: provision, diagnose, clean up and query remote runners "
            + "(docs/remote-runner.md §14/§16.4/§16.5)",
        subcommands: [Status.self, Clean.self, Unlock.self, Setup.self, Align.self, Exec.self, Hosts.self])

    // MARK: - status

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show reachability, login state, git revision, toolchain, and free disk space for a fleet of remote hosts (docs/remote-runner.md §16.5)")

        @Option(name: .customLong("host"), parsing: .upToNextOption,
                help: "Remote host to check: a registered name (ftester remote hosts) or a raw user@host/host. Repeatable, required")
        var hosts: [String] = []

        @Option(name: .customLong("remote-dir"),
                help: "Runner-only base directory on the remote host (default: the host registry's entry, or ~/ftester-runner)")
        var remoteDir: String?

        @Flag(help: "Also probe Foundation Models availability on each host (runs `<binary> doctor --fm-only`; adds a few seconds per host, so it is off by default)")
        var fm = false

        @Flag(help: "Emit one JSON object instead of a table")
        var json = false

        func run() async throws {
            guard !hosts.isEmpty else {
                throw ValidationError("no hosts specified (pass --host <name-or-user@host>)")
            }
            // 解決(登録簿の読み取りのみ)は並列プローブより先に、全ホストぶん一括で行う。
            // 失敗した解決はネットワークへ出さず即 unreachable 行にする
            var targets: [(raw: String, resolved: ResolvedRemoteHost)] = []
            var rows: [HostRow] = []
            for raw in hosts {
                do {
                    let resolved = try RemoteHostResolver.resolve(rawHost: raw, remoteDirOverride: remoteDir)
                    resolved.announce()
                    targets.append((raw, resolved))
                } catch {
                    rows.append(HostRow(sshTarget: raw, reachable: false,
                                        detail: error.localizedDescription, status: nil, fmOK: nil))
                }
            }
            let wantFM = fm
            let localRevision = localGitRevision()
            let localToolchain = ToolchainFingerprint.current()

            let probed: [HostRow] = await withTaskGroup(of: (Int, HostRow).self) { group in
                for (index, entry) in targets.enumerated() {
                    group.addTask {
                        (index, await RemoteStatusProbing.probe(entry.resolved, wantFM: wantFM))
                    }
                }
                var collected: [Int: HostRow] = [:]
                for await (index, row) in group { collected[index] = row }
                return targets.indices.compactMap { collected[$0] }
            }
            rows.append(contentsOf: probed)

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

    // MARK: - unlock

    /// 自分の死んだディスパッチが残した dispatch.lock だけを外す(判定は FTCore.RemoteDispatchUnlock)。
    /// `--force-lock` と違い他人の(走っているかもしれない)ロックは絶対に触らない
    struct Unlock: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "unlock",
            abstract: "Release the dispatch lock a dispatch of yours left behind on a remote host"
                + " (never touches another issuer's lock; docs/remote-runner.md §5)")

        @Option(name: .customLong("host"), parsing: .upToNextOption,
                help: "Remote host: a registered name (ftester remote hosts) or a raw user@host/host. Repeatable, required")
        var hosts: [String] = []

        @Option(name: .customLong("remote-dir"),
                help: "Runner-only base directory on the remote host (default: the host registry's entry, or ~/ftester-runner)")
        var remoteDir: String?

        func run() async throws {
            guard !hosts.isEmpty else {
                throw ValidationError("no hosts specified (pass --host <name-or-user@host>)")
            }
            var failures = 0
            for raw in hosts {
                print("== \(raw) ==")
                do {
                    try unlockOne(raw)
                } catch {
                    print("error: \(error.localizedDescription)")
                    failures += 1
                }
            }
            if failures > 0 { throw ExitCode(1) }
        }

        private func unlockOne(_ raw: String) throws {
            let resolved = try RemoteHostResolver.resolve(rawHost: raw, remoteDirOverride: remoteDir)
            resolved.announce()
            let target = resolved.hostSpec.sshTarget
            let layout = try Clean.resolveLayout(target: target, remoteDirRaw: resolved.remoteDirRaw)
            let probeResult = try Shell.run(remoteSSHBase + [target, RemoteDispatchLock.probeCommand(base: layout.base)])
            guard probeResult.status == 0, let probe = RemoteDispatchLock.parseProbe(probeResult.output) else {
                throw RemoteDispatchError.remoteSetupFailed(
                    "could not read the dispatch lock on \(target) (status \(probeResult.status))\n\(probeResult.tail)")
            }
            let decision = RemoteDispatchUnlock.decide(
                probe: probe, myIssuer: LocalConfig.resolveIssuerId(),
                myHost: ProcessInfo.processInfo.hostName, pidAlive: { kill($0, 0) == 0 })
            switch decision {
            case .nothingToDo:
                print("→ no dispatch lock on \(target); nothing to do")
            case .refuse(let reason):
                throw UnlockRefused(reason: reason)
            case .release(let reason):
                let release = try Shell.run(remoteSSHBase + [target, RemoteDispatchLock.releaseCommand(base: layout.base)])
                guard release.status == 0 else {
                    throw RemoteDispatchError.remoteSetupFailed(
                        "failed to remove the lock (status \(release.status))\n\(release.tail)")
                }
                print("→ released the dispatch lock on \(target) (\(reason))")
            }
        }
    }

    /// `remote unlock` が外さなかった理由(run() が localizedDescription を出すので LocalizedError)
    private struct UnlockRefused: LocalizedError {
        let reason: String
        var errorDescription: String? { "not released: \(reason)" }
    }

    // MARK: - clean

    struct Clean: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clean",
            abstract: "Stop orphaned bridges/simulators and delete results, reports, and dispatch leftovers older than --keep-days on remote hosts (docs/remote-runner.md §16.4)")

        @Option(name: .customLong("host"), parsing: .upToNextOption,
                help: "Remote host to clean: a registered name (ftester remote hosts) or a raw user@host/host. Repeatable, required")
        var hosts: [String] = []

        @Option(name: .customLong("remote-dir"),
                help: "Runner-only base directory on the remote host (default: the host registry's entry, or ~/ftester-runner)")
        var remoteDir: String?

        @Option(name: .customLong("keep-days"), help: "Delete results/reports/dispatch entries older than this many days")
        var keepDays: Int = 7

        @Flag(name: .customLong("dry-run"), help: "List what would be deleted instead of deleting it")
        var dryRun = false

        func run() async throws {
            guard !hosts.isEmpty else {
                throw ValidationError("no hosts specified (pass --host <name-or-user@host>)")
            }
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
            let resolved = try RemoteHostResolver.resolve(rawHost: raw, remoteDirOverride: remoteDir)
            resolved.announce()
            let target = resolved.hostSpec.sshTarget
            let layout = try Self.resolveLayout(target: target, remoteDirRaw: resolved.remoteDirRaw)

            if RemoteCleanPlan.stopsDevices(dryRun: dryRun) {
                // デバイスを止める前に片付ける(docs/remote-runner.md §17)。順序は逆にしない ——
                // 終了スクリプトはデバイスに触りうる(adb reverse の解除など)
                print("→ running teardown scripts left behind by dead runs")
                runReapAcrossIssuers(target: target, layout: layout)
                print("→ stopping bridges and shutting down simulators/emulators")
                let devicesDownCommand = RemoteShell.remoteRunCommand(
                    layout: layout, ftesterArgs: ["devices", "down"])
                let downResult = try Shell.run(remoteSSHBase + [target, devicesDownCommand])
                if downResult.status != 0 {
                    print("warning: `devices down` exited with status \(downResult.status)\n\(downResult.tail)")
                }
            } else {
                print("→ would stop bridges and shut down simulators/emulators (skipped: --dry-run)")
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
        static func resolveLayout(target: String, remoteDirRaw: String) throws -> RemoteLayout {
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
            return RemoteLayout(base: RemoteLayout.resolveBase(remoteDirRaw, home: home),
                               issuer: try resolveLayoutIssuer())
        }

        /// `hooks reap` を全発行者(`users/*`)+ 旧レイアウト(`work`)へ横断させる(§18.2)。
        /// ディスクはホスト共有資源なので、他の発行者が残した孤児 hooks も片付ける対象になる
        /// (RemoteCleanPlan.commands の reports/results 横断と同じ思想)
        private func runReapAcrossIssuers(target: String, layout: RemoteLayout) {
            let listResult = try? Shell.run(
                remoteSSHBase + [target, "ls -1 \(RemoteShell.quote(layout.usersDir)) 2>/dev/null"])
            let issuers = (listResult?.output ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for issuer in issuers {
                guard (try? RemoteLayout.validateIssuerKey(issuer)) != nil else { continue }
                runReap(target: target, layout: RemoteLayout(base: layout.base, issuer: issuer))
            }
            runLegacyReap(target: target, layout: layout)
        }

        /// **cd 失敗(その発行者の work がまだ無い)は exit 91 = skip として扱う**(エラーではない —
        /// 変更4の workspace ガードが返すだけの正常系。RemoteShell.remoteRunCommand 参照)
        private func runReap(target: String, layout: RemoteLayout) {
            let reapCommand = RemoteShell.remoteRunCommand(layout: layout, ftesterArgs: ["hooks", "reap"])
            guard let reapResult = try? Shell.run(remoteSSHBase + [target, reapCommand]) else {
                print("warning: failed to run `hooks reap` for issuer \(layout.issuer) (could not run ssh)")
                return
            }
            guard reapResult.status != 91 else { return }
            if reapResult.status != 0 {
                print("warning: `hooks reap` (issuer \(layout.issuer)) exited with status \(reapResult.status)\n\(reapResult.tail)")
                return
            }
            let trimmed = reapResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { print(trimmed) }
        }

        /// 旧レイアウト(`<base>/work`。発行者ネームスペース化前)の掃除。移行期だけの経路なので
        /// RemoteLayout.workDir(常に `users/<issuer>/work`)は使えない —— 存在しない/バイナリ未整備は
        /// 静かに無視する(ベストエフォート。ここで警告を出すと発行者ネームスペース化前の環境が
        /// 無かっただけの受け手にまでノイズが出る)
        private func runLegacyReap(target: String, layout: RemoteLayout) {
            let legacyWorkDir = layout.base + "/work"
            let binary = RemoteShell.quote(layout.binary)
            let command = "cd \(RemoteShell.quote(legacyWorkDir)) 2>/dev/null && test -f Package.swift && "
                + "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\" && "
                + "test -x \(binary) && \(binary) 'hooks' 'reap'"
            guard let result = try? Shell.run(remoteSSHBase + [target, command]), result.status == 0 else { return }
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { print(trimmed) }
        }
    }

    // MARK: - hosts

    struct Hosts: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "hosts",
            abstract: "Manage the --host registry (name -> ssh destination; docs/remote-runner.md §13)",
            subcommands: [List.self, Add.self, Remove.self],
            defaultSubcommand: List.self)

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list", abstract: "List registered remote hosts")

            @Flag(help: "Emit one JSON object instead of a table")
            var json = false

            func run() async throws {
                let entries = LocalConfig.load().remoteHosts ?? []
                if json {
                    Self.emitJSON(entries)
                } else {
                    Self.emitTable(entries)
                    for target in RemoteHostRegistry.duplicateTargets(entries) {
                        print("⚠️ multiple entries point at the same host: \(target)"
                            + " (dispatching to both fights over the same devices; docs/remote-runner.md §13)")
                    }
                }
            }

            private static func emitTable(_ entries: [RemoteHostEntry]) {
                let header = ["NAME", "HOST", "DIR"]
                var rows = [header]
                rows.append(contentsOf: entries.map { [$0.name, $0.host, $0.dir ?? "-"] })
                let widths = (0..<header.count).map { col in rows.map { $0[col].count }.max() ?? 0 }
                for row in rows {
                    let line = zip(row, widths)
                        .map { text, width in text + String(repeating: " ", count: max(0, width - text.count)) }
                        .joined(separator: "  ")
                    print(line)
                }
            }

            private static func emitJSON(_ entries: [RemoteHostEntry]) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                guard let data = try? encoder.encode(HostsListJSON(hosts: entries)),
                      let line = String(data: data, encoding: .utf8) else { return }
                print(line)
            }
        }

        struct Add: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "add", abstract: "Register or update a remote host (upsert by name)")

            @Argument(help: "Logical name for this host (letters, digits, _ . - only; \"local\" is reserved)")
            var name: String

            @Option(help: "SSH destination (user@host or host)")
            var host: String

            @Option(help: ArgumentHelp("Default base directory on this host (overrides the CLI default of ~/ftester-runner "
                + "unless --remote-dir is given explicitly on the dispatch command)"))
            var dir: String?

            func run() async throws {
                try RemoteHostRegistry.validateName(name)
                _ = try RemoteHostSpec.parse(host)
                if let dir { try RemoteLayout.validateBase(dir) }
                var config = LocalConfig.load()
                let entry = RemoteHostEntry(name: name, host: host, dir: dir)
                config.remoteHosts = RemoteHostRegistry.upsert(entry, into: config.remoteHosts ?? [])
                try config.save()
                print("✅ Registered host \"\(name)\" → \(host)")
                for target in RemoteHostRegistry.duplicateTargets(config.remoteHosts ?? []) where target == host {
                    print("⚠️ another entry already points at \(target)"
                        + " (dispatching to both fights over the same devices; docs/remote-runner.md §13)")
                }
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "remove", abstract: "Remove a registered remote host")

            @Argument(help: "Logical name to remove")
            var name: String

            func run() async throws {
                var config = LocalConfig.load()
                let before = config.remoteHosts ?? []
                guard before.contains(where: { $0.name == name }) else {
                    throw ValidationError("no host named \"\(name)\" is registered")
                }
                config.remoteHosts = RemoteHostRegistry.remove(name: name, from: before)
                try config.save()
                print("✅ Removed host \"\(name)\"")
            }
        }
    }
}

/// `ftester remote hosts list --json` の出力全体
private struct HostsListJSON: Encodable {
    let hosts: [RemoteHostEntry]
}

// MARK: - issuer resolution (choke point for every RemoteLayout construction; §18.2)

/// プロセス内で1回だけ、既定 issuer(USER@hostname フォールバック)を使った旨を stderr へ警告する
/// (actor は使わない: probe() が並列に呼ぶため NSLock で足りる最小限の排他だけ持つ)
private final class IssuerFallbackWarning: @unchecked Sendable {
    private let lock = NSLock()
    private var warned = false
    func shouldWarn() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !warned else { return false }
        warned = true
        return true
    }
}
private let issuerFallbackWarning = IssuerFallbackWarning()

/// リモートレイアウト用の issuer。検証し、明示設定でなければプロセスごとに1回だけ stderr へ警告する
/// (RemoteLayout を組み立てる全箇所がここを通る choke point。個別に LocalConfig.resolveIssuer を
/// 呼ばない)
func resolveLayoutIssuer() throws -> String {
    let (id, explicit) = LocalConfig.resolveIssuer()
    try RemoteLayout.validateIssuerKey(id)
    if !explicit, issuerFallbackWarning.shouldWarn() {
        FileHandle.standardError.write(Data(
            ("warning: using default issuer '\(id)' for the remote workspace namespace"
                + " — the default is derived from this machine's hostname, which can change on the network;"
                + " set issuerId in ~/.config/ftester/config.json (docs/remote-runner-setup.md)\n").utf8))
    }
    return id
}

// MARK: - --host resolution (shared by run/api run/remote status・clean・setup・exec)

/// `--host` の解決結果。**登録簿が優先**: 同名の登録があればそれを使い、無ければ raw を
/// そのまま ssh 宛先として扱う(docs/remote-runner.md §13)
struct ResolvedRemoteHost {
    let hostSpec: RemoteHostSpec
    /// 明示 `--remote-dir` > 登録簿の dir > CLI 既定("~/ftester-runner")
    let remoteDirRaw: String
    /// 登録名を経由したときだけ非 nil
    let registeredName: String?

    /// 登録名を使ったときに実行冒頭で出す1行。黙って別のマシンへ送らない
    /// (docs/remote-runner.md §13 レビュー指摘)
    var announcement: String? {
        registeredName.map { "==> host \($0) → \(hostSpec.sshTarget)" }
    }

    /// **print を使わない**。stdout が端末でないと行バッファが効かず、この1行だけが
    /// 最後まで出ない = 「どこへ送ったか」が進行より後に見える(実測)。NDJSON を stdout に
    /// 流す経路(api run / remote exec)は stderr へ出す
    func announce(toStderr: Bool = false) {
        guard let announcement else { return }
        let handle = toStderr ? FileHandle.standardError : FileHandle.standardOutput
        handle.write(Data((announcement + "\n").utf8))
    }
}

enum RemoteHostResolver {
    static let defaultRemoteDir = "~/ftester-runner"

    /// `remoteDirOverride` は `--remote-dir` の生値(未指定なら nil)。**未指定のときだけ**
    /// 登録簿の dir を既定として使う(明示指定は常に勝つ。CLAUDE.md「片方だけ変えない」— 4箇所
    /// (run/api run/remote status・clean/remote setup・exec)がここを通ることで規則を1つに保つ)
    static func resolve(rawHost: String, remoteDirOverride: String?) throws -> ResolvedRemoteHost {
        let entries = LocalConfig.load().remoteHosts ?? []
        switch RemoteHostRegistry.resolve(rawHost, entries: entries) {
        case .reserved:
            // RemoteDispatchError(LocalizedError 準拠)を使う。ArgumentParser.ValidationError は
            // LocalizedError を実装しておらず、ここは resolve() を内部で catch する呼び出し元
            // (Status/Clean)もあるため .localizedDescription で読めないと理由が消える
            // (RemoteCommands.Clean.resolveLayout のコメントと同じ罠)
            throw RemoteDispatchError.invalidHost(
                "must not be \"local\" or empty (\"local\" is reserved for local execution; "
                + "docs/remote-runner.md §13): \"\(rawHost)\"")
        case .registered(let entry):
            let dir = remoteDirOverride ?? entry.dir ?? defaultRemoteDir
            try RemoteLayout.validateBase(dir)
            return ResolvedRemoteHost(
                hostSpec: try RemoteHostSpec.parse(entry.host), remoteDirRaw: dir,
                registeredName: entry.name)
        case .rawTarget(let raw):
            let dir = remoteDirOverride ?? defaultRemoteDir
            try RemoteLayout.validateBase(dir)
            return ResolvedRemoteHost(
                hostSpec: try RemoteHostSpec.parse(raw), remoteDirRaw: dir, registeredName: nil)
        }
    }
}

// MARK: - --host ⊕ マシンプロファイルの host(共有。run/api run が使う。2026-08-17)

/// `--host`(明示)と `--profile` が解決するマシンプロファイルの `host`(自動)を統合した
/// 実効ディスパッチ先。`rawHost` の由来で登録簿引きの規則が変わる(下記 resolveRemoteTarget)
struct EffectiveHostDispatch {
    let rawHost: String
    /// true = マシンプロファイル由来(`--host` 未指定/"local"以外の理由で自動採用)。登録簿の
    /// 名前のみ受け付ける(生の ssh 宛先は書けない = MachineProfile.host の契約)。false =
    /// `--host` 由来で、既存どおり未登録名も生の ssh 宛先として扱う
    let requiresRegisteredName: Bool
    /// 自動ディスパッチ(requiresRegisteredName == true)のときのマシン名。RemoteDispatchFlagPolicy の
    /// 拒否理由文言だけに使う(欠陥1)。明示 `--host` 由来なら常に nil
    let autoDispatchMachineName: String?

    var origin: RemoteDispatchOrigin {
        autoDispatchMachineName.map { .autoDispatch(machine: $0, host: rawHost) } ?? .explicitHost
    }
}

/// `--host` とマシンプロファイルの `host` を突き合わせ、実効ディスパッチ先を決める
/// (優先順位・食い違いの判定は FTCore.MachineHostDispatch の純粋関数に委譲。ここは I/O だけ担当)。
///
/// - `--host` が明示されていれば、マシン側 host の読み取りはミスマッチ警告のためだけの
///   ベストエフォート(`try?`)。読めなくても `--host` での実行は妨げない
///   (リモートオーケストレータ機がローカルにマシンプロファイルを持たない構成でも壊さない)
/// - `--host` 未指定で `requireMachineHost` なら、マシン側 host を確定させる必要がある
///   (自動ディスパッチの唯一の判断材料なので、読めなければここで素直にエラーにする——
///   どのみち通常のローカル実行でも同じ理由でこの先失敗する)
/// - `requireMachineHost: false` かつ `--host` 未指定なら常に nil(呼び出し側が dry-run 等で
///   マシン側 host を見ない選択をしたとき用)
///
/// **`MachineHostDispatch.normalize` は "local"/空文字/未指定を同じ nil に畳むが、"local" だけは
/// 明示のローカル指定として resolve() 側で別扱いする**(欠陥3。この関数はここでは判定せず、
/// 生の explicitHost をそのまま `MachineHostDispatch.resolve` へ渡して委ねる)。machineHost の
/// 読み取り自体は「未指定」と同じ経路で行ってよい —— 読めても resolve() が "local" を優先するので
/// 安全側に倒れる
func resolveEffectiveHostDispatch(
    explicitHost: String?, profile: String?, project: String?,
    requireMachineHost: Bool, warn: (String) -> Void
) throws -> EffectiveHostDispatch? {
    let explicitNormalized = MachineHostDispatch.normalize(explicitHost)
    var machineHost: String?
    var machineName: String?
    if let profile {
        if explicitNormalized != nil {
            let resolved = try? machineProfileHostAndName(profile: profile, project: project)
            machineHost = resolved?.host
            machineName = resolved?.name
        } else if requireMachineHost {
            let resolved = try machineProfileHostAndName(profile: profile, project: project)
            machineHost = resolved.host
            machineName = resolved.name
        }
    }
    let decision = MachineHostDispatch.resolve(explicitHost: explicitHost, machineHost: machineHost)
    if let warning = decision.mismatchWarning { warn(warning) }
    guard let rawHost = decision.host else { return nil }
    let requiresRegisteredName = explicitNormalized == nil
    return EffectiveHostDispatch(
        rawHost: rawHost, requiresRegisteredName: requiresRegisteredName,
        autoDispatchMachineName: requiresRegisteredName ? machineName : nil)
}

/// **デバイスが居る機械が優先**。マシンプロファイルの `host` は「そのプロファイルの既定」で、
/// デバイス1台ずつが自分の host を持てる(DeviceHostGrouping)。実際に回す全デバイスが同じ機械に
/// 居るならそこがディスパッチ先 —— 既定を見るだけだと、`host` を書いていないマシンプロファイルに
/// リモートのデバイスだけを並べた形が**黙って手元で走る**(そのデバイスは手元に無いので落ちる)。
/// 複数の機械にまたがる場合はここへ来る前に DeviceHostRunner が引き取っているので、
/// 残りは「絞り込みで1つに定まらなかった」= 既定に従う場合だけ
private func machineProfileHostAndName(
    profile: String, project: String?
) throws -> (host: String?, name: String) {
    let testProject = try ScenarioHost.project(named: project)
    let machine = try ProfileResolver.determineMachine(
        project: testProject, runProfileName: profile)
    let devices = (try? ProfileResolver.runDeviceHosts(
        project: testProject, runProfileName: profile, machineName: machine.name)) ?? []
    let hosts = Set(devices.map { DeviceHostGrouping.display($0.host) })
    if hosts.count == 1, let only = hosts.first {
        return (only == DeviceHostGrouping.localDisplayName ? nil : only, machine.name)
    }
    let host = try ProfileResolver.machineHost(project: testProject, machineName: machine.name)
    return (host, machine.name)
}

/// `EffectiveHostDispatch` → `ResolvedRemoteHost`。マシンプロファイル由来
/// (`requiresRegisteredName`)なら登録簿の名前だけを受け付け、無ければ候補一覧付きで落とす
/// (黙ってローカル実行しない)。`--host` 由来は既存どおり `RemoteHostResolver.resolve` に委ねる
/// (未登録名は生の ssh 宛先として扱う)
func resolveRemoteTarget(_ dispatch: EffectiveHostDispatch, remoteDirOverride: String?) throws -> ResolvedRemoteHost {
    guard dispatch.requiresRegisteredName else {
        return try RemoteHostResolver.resolve(rawHost: dispatch.rawHost, remoteDirOverride: remoteDirOverride)
    }
    let entries = LocalConfig.load().remoteHosts ?? []
    guard case .registered = RemoteHostRegistry.resolve(dispatch.rawHost, entries: entries) else {
        throw RemoteDispatchError.invalidHost(
            "the machine profile's host \"\(dispatch.rawHost)\" is not a registered remote host"
            + (entries.isEmpty
               ? " (no hosts registered — run: ftester remote hosts add <name> --host <user@host>)"
               : " (available: \(entries.map(\.name).sorted().joined(separator: ", ")))"))
    }
    return try RemoteHostResolver.resolve(rawHost: dispatch.rawHost, remoteDirOverride: remoteDirOverride)
}

// MARK: - shared helpers

/// ホスト混在プロファイルの単一ホストディスパッチに付ける --device/--device-host を決める
/// (判定は FTCore.RemoteDispatchDeviceScope / 明示 --device 付きは RemoteDispatchExplicitDeviceScope)。
/// 呼び出し側が既に --device-host を持つときは呼ばないこと。`requestedDevices` は利用者の
/// 明示 `--device`(空 = 無し)—— 混在プロファイルではそのホストの台に限定して渡す
/// (同名の台が他の機械にもあると、名前だけでは全機械ぶんを拾う)。
/// プロファイル/マシンが読めないときは従来どおり丸ごと(名前はそのまま・host は付けない)
func hostScopedDeviceFilter(
    project: TestProject, profile: String, targetHost: String, requestedDevices: [String] = []
) throws -> (deviceNames: [String], deviceHost: String?) {
    guard let machine = try? ProfileResolver.determineMachine(project: project, runProfileName: profile) else {
        return (requestedDevices, nil)
    }
    let devices = (try? ProfileResolver.runDeviceHosts(
        project: project, runProfileName: profile, machineName: machine.name)) ?? []
    if !requestedDevices.isEmpty {
        switch RemoteDispatchExplicitDeviceScope.resolve(
            targetHost: targetHost, requested: requestedDevices, devices: devices) {
        case .passThrough:
            return (requestedDevices, nil)
        case .pinned:
            return (requestedDevices, targetHost)
        case .notOnHost(let missing, let available):
            throw RemoteDispatchError.invalidDevice(
                "\(missing.map { "\"\($0)\"" }.joined(separator: ", ")) is not assigned to host"
                + " \"\(targetHost)\" in profile \"\(profile)\""
                + (available.isEmpty ? " (it has no devices there)"
                   : " (its devices there: \(available.map { "\"\($0)\"" }.joined(separator: ", ")))")
                + " — with --host, --device is limited to that host's devices;"
                + " pass --device-host to target another machine's device of the same name")
        }
    }
    switch RemoteDispatchDeviceScope.resolve(targetHost: targetHost, devices: devices) {
    case .wholeProfile:
        return ([], nil)
    case .filtered(let names):
        return (names, targetHost)
    case .noneForHost(let hosts):
        throw RemoteDispatchError.invalidHost(
            "profile \"\(profile)\" assigns no devices to host \"\(targetHost)\""
            + " (its devices are pinned to: \(hosts.joined(separator: ", ")))"
            + " — add devices for \(targetHost) to the machine profile,"
            + " or pass --device/--device-host explicitly")
    }
}

/// 1ホスト分のプローブ(ssh 1回)。`remote status` と `api remote-compat`(拡張の実行前チェック)が
/// 共有する ―― 挙動は変えず、`remote status` の private 実装をそのまま外出しした
enum RemoteStatusProbing {
    /// 到達性・rev・toolchain・binary・空き容量をまとめて取る。layout.base はここでは $HOME を
    /// 未解決のまま埋め込んだ式になり得る(RemoteLayout.resolveBase(raw, home: "$HOME") —
    /// 全ホスト並列・1 ssh 呼び出しに収める設計のため、$HOME 解決だけの往復を別に持たない。
    /// リモートシェルが実行時に自分の $HOME で展開する。RemoteStatusProbe.command が
    /// 二重引用符で包むのはこのため)
    static func probe(_ resolved: ResolvedRemoteHost, wantFM: Bool) async -> HostRow {
        let target = resolved.hostSpec.sshTarget
        do {
            let layout = RemoteLayout(base: RemoteLayout.resolveBase(resolved.remoteDirRaw, home: "$HOME"),
                                      issuer: try resolveLayoutIssuer())
            let command = RemoteStatusProbe.command(layout: layout)
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
}

/// remote status の1ホスト分の生行(mismatch 判定前)。Sendable なのはタスクグループの
/// 境界を越えて返すため。`api remote-compat` も同じ形を使う
struct HostRow: Sendable {
    let sshTarget: String
    let reachable: Bool
    let detail: String?
    let status: RemoteHostStatus?
    let fmOK: Bool?
}

/// HostRow にローカル値との適合判定を添えたもの(表示直前に1回だけ計算する。
/// タスクグループはローカル値を必要としないため HostRow には含めない)。
/// `api remote-compat` も同じ mismatchReasons を使って revisionCompatible/toolchainCompatible を出す
struct HostReport {
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

/// `remote status` と `api remote-compat` が共有(`api remote-compat` はホストが1台も無いときも
/// ローカル revision を出すため呼ぶ)
func localGitRevision() -> String? {
    guard let root = try? RepoRoot.find(),
          let result = try? Shell.run(["git", "-C", root.path, "rev-parse", "HEAD"]),
          result.status == 0 else { return nil }
    let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return output.isEmpty ? nil : output
}

/// そのコミットがリモート追跡ブランチに含まれるか(= push 済みか)。判定不能なら published 扱い
/// (助言を足すかどうかの判断であって、実行を止める判定ではない)。RemoteRunDispatcher /
/// RemoteSetupCommand.Setup / ApiRemoteCompatCommand が共有する
func revisionIsPublished(repoRoot: URL, revision: String) -> Bool {
    guard let result = try? Shell.run(
        ["git", "-C", repoRoot.path, "branch", "-r", "--contains", revision]),
          result.status == 0 else { return true }
    return !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// rev 不一致の解消の向き(docs/remote-runner.md §18.3 規則1)。**fetch はしない**
/// (チェック経路にネットワーク副作用を持ち込まない。update-check.sh と同じ思想) ——
/// remoteRevision がこの clone に無ければ .unknown。RemoteRunDispatcher.checkCompatibility /
/// ApiRemoteCompatCommand が共有する
func revisionRelation(repoRoot: URL, localRevision: String, remoteRevision: String) -> RevisionRelation {
    guard let existsResult = try? Shell.run(
        ["git", "-C", repoRoot.path, "cat-file", "-e", "\(remoteRevision)^{commit}"]),
          existsResult.status == 0 else {
        return .unknown
    }
    let localIsAncestor = isAncestorRevision(repoRoot: repoRoot, ancestor: localRevision, descendant: remoteRevision)
    let remoteIsAncestor = isAncestorRevision(repoRoot: repoRoot, ancestor: remoteRevision, descendant: localRevision)
    return RemoteCompat.classifyRelation(
        localIsAncestorOfRemote: localIsAncestor, remoteIsAncestorOfLocal: remoteIsAncestor)
}

/// `git merge-base --is-ancestor` の exit code: 0=true / 1=false / それ以外(不正な rev・
/// git 自体が起動できない等)は判定不能として nil
private func isAncestorRevision(repoRoot: URL, ancestor: String, descendant: String) -> Bool? {
    guard let result = try? Shell.run(
        ["git", "-C", repoRoot.path, "merge-base", "--is-ancestor", ancestor, descendant]) else {
        return nil
    }
    switch result.status {
    case 0: return true
    case 1: return false
    default: return nil
    }
}

private func formatFreeSpace(_ kb: Int) -> String {
    String(format: "%.1f GB", Double(kb) / 1024 / 1024)
}
