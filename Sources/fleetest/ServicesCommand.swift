// ServicesCommand.swift
// `fleetest services`: ワークスペースのサービス(scripts/compose.yaml)の状態の確認と、人が打つ一掃
// (docs/remote-runner.md §17「人の入口」)。起動と終了そのものは run が行う(ServicesSession)。

import ArgumentParser
import Foundation
import FTBridgeClient
import FTCore
import FTServices

struct ServicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "services",
        abstract: "Inspect or reset the services a workspace declares in scripts/compose.yaml (docs/remote-runner.md §17)",
        subcommands: [Status.self, Reset.self])

    struct Target {
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
        return Target(workspace: workspace, prefix: prefix, stateDir: stateDir, project: testProject.name)
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
                    ConsoleOut.out("lease \(entry.url.lastPathComponent): pid \(lease.pid) \(orphan ? "not running (orphan)" : "running"),"
                        + " phase \(lease.phase.rawValue), \(lease.runtime), containers [\(lease.containers.keys.sorted().joined(separator: ", "))],"
                        + " networks [\(lease.networks.keys.sorted().joined(separator: ", "))]")
                }
            }

            do {
                let cli = try ServicesCommand.runtime(for: entries)
                ConsoleOut.out("runtime: \(cli.runtime.kind.rawValue) (\(cli.runtime.executable))")
                let listing = ServicesCommand.list(cli: cli, prefix: target.prefix)
                for item in listing.containers { ConsoleOut.out("  container \(item.name) \(item.id)") }
                for item in listing.networks { ConsoleOut.out("  network \(item.name) \(item.id)") }
                for item in listing.volumes { ConsoleOut.out("  volume \(item.name)") }
                if listing.containers.isEmpty && listing.networks.isEmpty && listing.volumes.isEmpty && listing.failures.isEmpty {
                    ConsoleOut.out("  (no resources with this prefix)")
                }
                for failure in listing.failures { ConsoleOut.out("⚠️ \(failure)") }
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

        @Flag(help: "Remove everything even if a run still holds the services or a lease cannot be read")
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
                            throw ValidationError("run pid \(lease.pid) holds these services; stop it first, or rerun with --force")
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
