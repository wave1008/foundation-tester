// ServicesCommand.swift
// `fleetest services`: ワークスペースのサービス(scripts/compose.yaml)を人が起こす・止める・見る・一掃する
// (docs/remote-runner.md §17「人の入口」「調停」)。run の間の起動と終了は run が行う(ServicesSession)。
// `up` は常駐の所有者(`fleetest api services-owner`)を起こして上がるまで待つ。`down` は所有者へ SIGTERM を送り終了を待つ。
// run が握っているサービスは `down` も `reset`(--force 無し)も触らない。

import ArgumentParser
import Foundation
import FTBridgeClient
import FTCore
import FTServices

struct ServicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "services",
        abstract: "Start, stop, inspect or reset the services a workspace declares in scripts/compose.yaml (docs/remote-runner.md §17)",
        subcommands: [Up.self, Down.self, Status.self, Pull.self, Load.self, Reset.self])

    struct Target {
        let resolved: ResolvedProfile
        let workspace: ServicesWorkspace
        let prefix: String
        let stateDir: URL
        let project: String
    }

    /// `--project` / `--profile` は run と同じ解決(プロジェクトは唯一・または既定、プロファイルは唯一なら省略可)。
    static func resolveTarget(project: String?, profile: String?) throws -> Target {
        let testProject = try ScenarioHost.project(named: project)
        let names = ProfileResolver.runProfileNames(project: testProject)
        let profileName: String
        if let profile {
            profileName = profile
        } else if names.count == 1, let only = names.first {
            profileName = only
        } else {
            throw ValidationError("--profile is required (available: \(names.joined(separator: ", ")))")
        }
        let resolved = try ProfileResolver.resolve(project: testProject, runName: profileName)
        let workspace = ServicesFacts.workspace(for: resolved)
        let prefix = ServicePlanner.prefix(forWorkspace: ServicesFacts.workspaceRealpath(workspace))
        let stateDir = try RepoRoot.find().appendingPathComponent(".fleetest")
        return Target(resolved: resolved, workspace: workspace, prefix: prefix, stateDir: stateDir, project: testProject.name)
    }

    struct Listing {
        var containers: [(id: String, name: String)] = []
        var networks: [(id: String, name: String)] = []
        var volumes: [(id: String, name: String)] = []
        var failures: [String] = []
    }

    /// ランタイム上の接頭辞の資源。ラベルを持たない中継・エコーも拾うため、名前で絞る。
    static func list(cli: RuntimeCLI, prefix: String) -> Listing {
        var listing = Listing()
        let commands = cli.commands
        func collect(_ label: String, _ argv: [String]) -> [(id: String, name: String)] {
            let result = cli.run(argv)
            guard result.succeeded else {
                listing.failures.append("listing \(label) failed (exit \(result.status)): \(result.tail(lines: 2))")
                return []
            }
            return RuntimeListing.parse(result.output, isDocker: cli.isDocker)
                .filter { RuntimeListing.belongs($0.name, prefix: prefix) }
        }
        listing.containers = collect("containers", commands.listContainers)
        listing.networks = collect("networks", commands.listNetworks)
        listing.volumes = collect("volumes", commands.listVolumes)
        return listing
    }

    /// 控えが指すランタイム → 無ければ今の設定(Apple の常駐サービスは起こさない)。
    static func runtime(for entries: [ServicesLeaseEntry]) throws -> RuntimeCLI {
        if let lease = entries.compactMap(\.lease).first, let kind = ServiceRuntime(rawValue: lease.runtime),
           let executable = ServicesRuntimeLocator.executable(for: kind) {
            return RuntimeCLI(runtime: LocatedRuntime(kind: kind, executable: executable, endpoint: lease.endpoint))
        }
        let located = try ServicesRuntimeLocator.locate(settings: try ServicesSettings.load(), allowStart: false) {
            ConsoleOut.out($0)
        }
        return RuntimeCLI(runtime: located)
    }

    /// 所有者(pid・開始時刻)の終了を待つ。上限はその控えの片付けの予算。尽きたら false(所有者は片付けを続けている)。
    static func waitForExit(pid: Int32, startedAt: String, budgetSeconds: Double) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + budgetSeconds
        while ServicesProcessIdentity.isAlive(pid: pid, startedAt: startedAt) {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            Thread.sleep(forTimeInterval: ServicesSession.pollIntervalSeconds)
        }
        return true
    }

    struct Up: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "up",
            abstract: "Start this workspace's services and keep them running until `services down`"
                + " (for exploration, live control and scenario writing; a run takes them over and starts them again)")

        @Option(name: .long, help: "Test project (defaults to the only one in TestProjects/, or the default project)")
        var project: String?

        @Option(name: .long, help: "Run profile (optional when the project has exactly one)")
        var profile: String?

        @Flag(help: "Also publish the ports on this Mac's LAN address (services.publishForPhysicalDevices) for physical devices")
        var physical = false

        @Option(name: .long, help: "Android physical device (adb serial) that receives `adb reverse` for each published TCP port; repeatable")
        var serial: [String] = []

        func run() async throws {
            let target = try ServicesCommand.resolveTarget(project: project, profile: profile)
            guard target.workspace.hasComposeFile else {
                ConsoleOut.out("→ services: no scripts/compose.yaml in \(target.workspace.root.path); nothing to start")
                return
            }
            // 既に上がっていれば何もしない(MCP から繰り返し呼べる)。run が握っていれば断る
            let before = ServicesLeaseStore.entries(stateDir: target.stateDir, prefix: target.prefix)
            for lease in before.compactMap(\.lease)
            where !ServicesLeaseFile.isOrphan(lease, isAlive: ServicesProcessIdentity.isAlive) {
                switch lease.kind {
                case .owner:
                    ConsoleOut.out("→ services: already up (\(lease.holderDescription)); stop with `fleetest services down`")
                    Self.printPublished(lease)
                    return
                case .run:
                    throw ValidationError("\(lease.holderDescription) holds these services; wait for that run to finish")
                }
            }
            guard let executable = Bundle.main.executableURL else {
                throw ValidationError("cannot locate the fleetest executable to start the services owner")
            }
            let logURL = ServicesOwnerLaunch.logURL(stateDir: target.stateDir, prefix: target.prefix)
            let (owner, ownerExited) = try ServicesOwnerLaunch.spawn(
                executable: executable, project: target.project, profile: target.resolved.runName,
                physical: physical, serials: serial, logURL: logURL)
            ConsoleOut.out("→ services: starting (owner pid \(owner.processIdentifier), log \(logURL.path))")

            let interrupted = LockedValue(false)
            let relay = InterruptRelay.observing { interrupted.value = true }
            defer { relay.stop() }
            while true {
                if interrupted.value {
                    _ = kill(owner.processIdentifier, SIGTERM)
                    ownerExited()
                    ConsoleOut.err("⏹ services up interrupted; the owner was stopped (exit \(owner.terminationStatus))")
                    throw ExitCode(130)
                }
                let entries = ServicesLeaseStore.entries(stateDir: target.stateDir, prefix: target.prefix)
                switch ServicesOwnerLaunch.readiness(entries: entries, ownerPid: owner.processIdentifier, ownerRunning: owner.isRunning) {
                case .running(let lease):
                    ConsoleOut.out("→ services: up (\(lease.holderDescription)); stop with `fleetest services down`")
                    Self.printPublished(lease)
                    return
                case .exited:
                    ConsoleOut.err("✗ services up failed (owner exit \(owner.terminationStatus)); last log lines (\(logURL.path)):")
                    for line in ServicesOwnerLaunch.logTail(logURL, lines: 20) { ConsoleOut.err("  " + line) }
                    throw ExitCode.failure
                case .waiting:
                    try await Task.sleep(nanoseconds: UInt64(ServicesSession.pollIntervalSeconds * 1_000_000_000))
                }
            }
        }

        private static func printPublished(_ lease: ServicesLease) {
            for line in lease.publishedSummary { ConsoleOut.out("  " + line) }
            for entry in lease.adbReverse { ConsoleOut.out("  adb reverse \(entry.serial) tcp:\(entry.hostPort)") }
        }
    }

    struct Down: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "down",
            abstract: "Stop the services started by `services up` (services held by a run are left to that run)")

        @Option(name: .long, help: "Test project (defaults to the only one in TestProjects/, or the default project)")
        var project: String?

        @Option(name: .long, help: "Run profile (optional when the project has exactly one)")
        var profile: String?

        func run() async throws {
            let target = try ServicesCommand.resolveTarget(project: project, profile: profile)
            struct Owner { let pid: Int32; let startedAt: String; let budget: Double }
            var owners: [Owner] = []
            var reaped = 0
            let log: (String) -> Void = { ConsoleOut.out($0) }
            // 「確認 → 合図」は排他の中で。終了の待ちは排他の外で(所有者は同じ排他の中で片付ける)
            try ServicesLock.withLock(prefix: target.prefix, stateDir: target.stateDir) {
                for entry in ServicesLeaseStore.entries(stateDir: target.stateDir, prefix: target.prefix) {
                    switch entry.state {
                    case .unreadable(let reason):
                        ConsoleOut.out("⚠️ lease \(entry.url.lastPathComponent): unreadable (\(reason)); not removed —"
                            + " `fleetest services reset --force` clears it")
                    case .readable(let lease):
                        if ServicesLeaseFile.isOrphan(lease, isAlive: ServicesProcessIdentity.isAlive) {
                            if ServicesReaper.reapOne(entry: entry, lease: lease, home: NSHomeDirectory(),
                                                      remover: ServicesReaper.defaultRemover(log: log), log: log) {
                                reaped += 1
                            }
                        } else if lease.kind == .run {
                            throw ValidationError("\(lease.holderDescription) holds these services; they stop when that run finishes")
                        } else {
                            ConsoleOut.out("→ services: stopping \(lease.holderDescription)")
                            _ = kill(lease.pid, SIGTERM)
                            owners.append(Owner(pid: lease.pid, startedAt: lease.pidStartedAt,
                                                budget: ServicesTeardown.teardownBudgetSeconds(lease: lease)))
                        }
                    }
                }
            }
            for owner in owners {
                guard ServicesCommand.waitForExit(pid: owner.pid, startedAt: owner.startedAt, budgetSeconds: owner.budget) else {
                    ConsoleOut.err("⚠️ services: pid \(owner.pid) is still stopping after \(Int(owner.budget))s;"
                        + " check `fleetest services status` later")
                    throw ExitCode.failure
                }
            }
            // 所有者が片付けに失敗して残した控え(資源あり)は孤児 = ここでもう一度試す
            if !owners.isEmpty {
                for entry in ServicesLeaseStore.entries(stateDir: target.stateDir, prefix: target.prefix) {
                    guard let lease = entry.lease, ServicesLeaseFile.isOrphan(lease, isAlive: ServicesProcessIdentity.isAlive) else { continue }
                    _ = ServicesReaper.reapOne(entry: entry, lease: lease, home: NSHomeDirectory(),
                                               remover: ServicesReaper.defaultRemover(log: log), log: log)
                }
            }
            if owners.isEmpty && reaped == 0 {
                ConsoleOut.out("→ services: nothing is up for this workspace")
            } else {
                ConsoleOut.out("→ services: down (\(owners.count) owner(s) stopped, \(reaped) leftover(s) removed)")
            }
        }
    }

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pull",
            abstract: "Pull the images compose.yaml declares ahead of a run (and build the relay image on first use);"
                + " --refresh pulls them again even when they are already present")

        @Option(name: .long, help: "Test project (defaults to the only one in TestProjects/, or the default project)")
        var project: String?

        @Option(name: .long, help: "Run profile (optional when the project has exactly one)")
        var profile: String?

        @Flag(help: "Pull every declared image again, replacing the local copy")
        var refresh = false

        func run() async throws {
            let target = try ServicesCommand.resolveTarget(project: project, profile: profile)
            do {
                let result = try ServicesSession.pull(
                    resolved: target.resolved, options: .forRun(target.resolved), refresh: refresh) { ConsoleOut.out($0) }
                ConsoleOut.out("→ services pull: \(result.pulled) image(s) pulled, \(result.present) already present")
            } catch let error as ServicesError {
                ConsoleOut.err("✗ \(error.shortDescription)")  // run の外 = 「シナリオは走らなかった」を付けない
                throw ExitCode.failure
            }
        }
    }

    struct Load: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "load",
            abstract: "Load images from a tar archive (`docker save` / `container image save`) into this Mac's container runtime,"
                + " for machines without network access to the registry")

        @Argument(help: "Path of the image archive")
        var file: String

        func run() async throws {
            let path = (file as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw ValidationError("\(path) does not exist")
            }
            let cli: RuntimeCLI
            do {
                let located = try ServicesRuntimeLocator.locate(settings: try ServicesSettings.load()) { ConsoleOut.out($0) }
                cli = RuntimeCLI(runtime: located)
            } catch let error as ServicesError {
                ConsoleOut.err("✗ \(error.shortDescription)")
                throw ExitCode.failure
            }
            ConsoleOut.out("→ services load: \(path) into \(cli.runtime.kind.rawValue)")
            let result = cli.runLong(cli.commands.imageLoad(path), label: "the image load", interrupt: nil) { ConsoleOut.out($0) }
            guard result.status == 0 else {
                ConsoleOut.err("✗ services: loading \(path) failed (exit \(result.status)): \(result.tail.suffix(5).joined(separator: " | "))")
                throw ExitCode.failure
            }
            for line in result.tail.suffix(5) { ConsoleOut.out("  " + line) }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show the leases, the lock and the runtime resources of this workspace's services")

        @Option(name: .long, help: "Test project (defaults to the only one in TestProjects/, or the default project)")
        var project: String?

        @Option(name: .long, help: "Run profile (optional when the project has exactly one)")
        var profile: String?

        func run() async throws {
            let target = try ServicesCommand.resolveTarget(project: project, profile: profile)
            ConsoleOut.out("workspace: \(target.workspace.root.path)")
            ConsoleOut.out("compose.yaml: \(target.workspace.hasComposeFile ? "present" : "absent") (\(target.workspace.composeFile.path))")
            ConsoleOut.out("prefix: \(target.prefix)")

            if let holder = ServicesLock.currentHolder(prefix: target.prefix, stateDir: target.stateDir) {
                let alive = ServicesProcessIdentity.isAlive(pid: holder.pid, startedAt: holder.startedAt)
                ConsoleOut.out("lock: held by pid \(holder.pid) (\(alive ? "running" : "not running"))")
            } else {
                ConsoleOut.out("lock: free")
            }

            let entries = ServicesLeaseStore.entries(stateDir: target.stateDir, prefix: target.prefix)
            if entries.isEmpty { ConsoleOut.out("leases: none") }
            for entry in entries {
                switch entry.state {
                case .unreadable(let reason):
                    ConsoleOut.out("lease \(entry.url.lastPathComponent): unreadable (\(reason)) — not removed;"
                        + " `fleetest services reset --force` clears it")
                case .readable(let lease):
                    let orphan = ServicesLeaseFile.isOrphan(lease, isAlive: ServicesProcessIdentity.isAlive)
                    ConsoleOut.out("lease \(entry.url.lastPathComponent): \(lease.holderDescription) \(orphan ? "not running (orphan)" : "running"),"
                        + " phase \(lease.phase.rawValue), \(lease.runtime), containers [\(lease.containers.keys.sorted().joined(separator: ", "))],"
                        + " networks [\(lease.networks.keys.sorted().joined(separator: ", "))]")
                    for line in lease.publishedSummary { ConsoleOut.out("  published \(line)") }
                    for reverse in lease.adbReverse { ConsoleOut.out("  adb reverse \(reverse.serial) tcp:\(reverse.hostPort)") }
                }
            }

            do {
                let cli = try ServicesCommand.runtime(for: entries)
                ConsoleOut.out("runtime: \(cli.runtime.kind.rawValue) (\(cli.runtime.executable))")
                let listing = ServicesCommand.list(cli: cli, prefix: target.prefix)
                for item in listing.containers { ConsoleOut.out("  container \(item.name) \(item.id)") }
                for item in listing.networks { ConsoleOut.out("  network \(item.name) \(item.id)") }
                // ボリュームと fleetest が作ったイメージは大きさつき(ボリュームは消さないので、人が見て `services reset` を決める口)
                let sizes = ServicesSizes.report(cli: cli, prefix: target.prefix, volumes: listing.volumes.map(\.name))
                for line in sizes.volumeLines { ConsoleOut.out("  " + line) }
                for line in sizes.imageLines { ConsoleOut.out("  " + line) }
                if listing.containers.isEmpty && listing.networks.isEmpty && listing.volumes.isEmpty && sizes.imageLines.isEmpty
                    && listing.failures.isEmpty {
                    ConsoleOut.out("  (no resources with this prefix)")
                }
                for failure in listing.failures + sizes.failures { ConsoleOut.out("⚠️ \(failure)") }
            } catch {
                ConsoleOut.out("runtime: unavailable (\((error as? ServicesError)?.shortDescription ?? error.localizedDescription))")
            }
        }
    }

    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reset",
            abstract: "Remove this workspace's service containers, networks and volumes, and its leases and lock")

        @Option(name: .long, help: "Test project (defaults to the only one in TestProjects/, or the default project)")
        var project: String?

        @Option(name: .long, help: "Run profile (optional when the project has exactly one)")
        var profile: String?

        @Flag(help: "Remove everything even if a run or `services up` still holds the services or a lease cannot be read")
        var force = false

        func run() async throws {
            let target = try ServicesCommand.resolveTarget(project: project, profile: profile)
            let entries = ServicesLeaseStore.entries(stateDir: target.stateDir, prefix: target.prefix)

            if !force {
                for entry in entries {
                    switch entry.state {
                    case .unreadable(let reason):
                        throw ValidationError("the lease \(entry.url.lastPathComponent) cannot be read (\(reason)); rerun with --force to remove the services anyway")
                    case .readable(let lease):
                        if !ServicesLeaseFile.isOrphan(lease, isAlive: ServicesProcessIdentity.isAlive) {
                            let how = lease.kind == .owner ? "`fleetest services down`" : "wait for the run"
                            throw ValidationError("\(lease.holderDescription) holds these services; stop it first (\(how)), or rerun with --force")
                        }
                    }
                }
                if let holder = ServicesLock.currentHolder(prefix: target.prefix, stateDir: target.stateDir),
                   ServicesProcessIdentity.isAlive(pid: holder.pid, startedAt: holder.startedAt) {
                    throw ValidationError("pid \(holder.pid) is creating or removing these services; wait for it, or rerun with --force")
                }
            }

            let cli: RuntimeCLI
            do {
                cli = try ServicesCommand.runtime(for: entries)
            } catch let error as ServicesError {
                ConsoleOut.err("✗ \(error.shortDescription)")  // run の外 = 「シナリオは走らなかった」を付けない
                throw ExitCode.failure
            }
            let listing = ServicesCommand.list(cli: cli, prefix: target.prefix)
            let commands = cli.commands
            var failed = listing.failures
            for item in listing.containers {
                let result = cli.run(commands.containerRemove(item.id))
                report("container \(item.name)", result, &failed)
            }
            for item in listing.networks {
                report("network \(item.name)", cli.run(commands.networkRemove(item.id)), &failed)
            }
            for item in listing.volumes {
                report("volume \(item.name)", cli.run(commands.volumeRemove(item.name)), &failed)
            }
            // 控えの adb reverse も外す(資源ではないので失敗は警告だけ)
            ServicesAdbReverse.removeAll(entries.compactMap(\.lease).flatMap(\.adbReverse)) { ConsoleOut.out($0) }

            guard failed.isEmpty else {
                // 消せなかったものがあるので、控えとロックは残す(再試行できるように)
                for line in failed { ConsoleOut.out("⚠️ \(line)") }
                throw ExitCode.failure
            }
            for entry in entries {
                try? FileManager.default.removeItem(at: entry.url)
                ServicesReaper.removePrivateDirectory(home: NSHomeDirectory(), pid: entry.pid)
            }
            ServicesLock.forceRelease(prefix: target.prefix, stateDir: target.stateDir)
            ConsoleOut.out("→ services reset: \(listing.containers.count) container(s), \(listing.networks.count) network(s),"
                + " \(listing.volumes.count) volume(s) removed; \(entries.count) lease(s) cleared")
        }

        private func report(_ what: String, _ result: RuntimeCLIResult, _ failed: inout [String]) {
            if result.succeeded || ServicesTeardown.isGone(result.output) {
                ConsoleOut.out("  removed \(what)")
            } else {
                failed.append("could not remove \(what) (exit \(result.status)): \(result.tail(lines: 2))")
            }
        }
    }
}
