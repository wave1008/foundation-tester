// ApiRemoteCompatCommand.swift
// `fleetest api remote-compat --project <P> --profile <X>`: 拡張の実行前チェック専用
// (人が読む表は `fleetest remote status`)。プロファイルのリモートホスト集合を求め、
// `RemoteStatusProbing`(RemoteCommands.swift。`remote status` と共有)で並列プローブし、
// JSON を1行 stdout へ出す。exit は常に 0 — ズレの有無は JSON で伝える契約(--project/--profile
// の解決エラーだけ非0)。

import ArgumentParser
import FTBridgeClient
import FTCore
import Foundation

struct ApiRemoteCompatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote-compat",
        abstract: "Report git revision / toolchain compatibility of a run profile's remote hosts,"
            + " for the extension's pre-run check (the human-readable table is `fleetest remote status`)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name")
    var profile: String

    @Option(name: .customLong("remote-dir"),
            help: ArgumentHelp("Runner-only base directory override for every host"
                + " (default: each host registry entry, or ~/fleetest-runner)"))
    var remoteDir: String?

    func run() async throws {
        let testProject = try ScenarioHost.project(named: project)
        let hostNames = try Self.remoteHostNames(project: testProject, profile: profile)

        let repoRoot = try? RepoRoot.find()
        let localRevision = localGitRevision()
        let localDirty = Self.localDirty(repoRoot: repoRoot)
        let localToolchain = ToolchainFingerprint.current()
        let published = Self.published(repoRoot: repoRoot, revision: localRevision)

        var hosts: [RemoteCompatHostJSON?] = Array(repeating: nil, count: hostNames.count)
        var targets: [(index: Int, resolved: ResolvedRemoteHost)] = []
        for (index, name) in hostNames.enumerated() {
            do {
                let resolved = try RemoteHostResolver.resolve(rawHost: name, remoteDirOverride: remoteDir)
                targets.append((index, resolved))
            } catch {
                hosts[index] = RemoteCompatHostJSON(
                    name: name, sshTarget: name, reachable: false, revision: nil,
                    revisionCompatible: nil, revisionRelation: nil, toolchain: nil, toolchainCompatible: nil,
                    error: error.localizedDescription)
            }
        }

        let probed: [Int: HostRow] = await withTaskGroup(of: (Int, HostRow).self) { group in
            for entry in targets {
                group.addTask { (entry.index, await RemoteStatusProbing.probe(entry.resolved, wantFM: false)) }
            }
            var collected: [Int: HostRow] = [:]
            for await (index, row) in group { collected[index] = row }
            return collected
        }
        for (index, row) in probed {
            let report = HostReport(row: row, localRevision: localRevision, localToolchain: localToolchain)
            let revisionCompatible = report.reachable
                ? !report.mismatchReasons.contains(where: { $0.hasPrefix("git revision") }) : nil
            let remoteRevision = report.status?.revision
            // published のときだけ向きを出す(未 push は align 案内が誤誘導になる。checkCompatibility と同じ規律)
            let relation: RevisionRelation? = {
                guard revisionCompatible == false, published,
                      let localRevision, let remoteRevision, let repoRoot else { return nil }
                return revisionRelation(repoRoot: repoRoot, localRevision: localRevision, remoteRevision: remoteRevision)
            }()
            hosts[index] = RemoteCompatHostJSON(
                name: hostNames[index], sshTarget: report.sshTarget, reachable: report.reachable,
                revision: remoteRevision,
                revisionCompatible: revisionCompatible,
                revisionRelation: relation?.rawValue,
                toolchain: report.status?.toolchain,
                toolchainCompatible: report.reachable
                    ? !report.mismatchReasons.contains(where: { $0.hasPrefix("toolchain") }) : nil,
                error: report.detail)
        }

        let output = RemoteCompatOutput(
            hosts: hosts.compactMap { $0 }, localDirty: localDirty, localRevision: localRevision,
            revisionPublished: published)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }

    /// この実行プロファイルが使うリモートホストのラベル一覧(登録名。docs/remote-runner.md §13 —
    /// マシンプロファイルの host は登録名でしか書けない契約)。ホストが2機以上にまたがっていれば
    /// DeviceHostRunner の分割計画から、単一機械の自動ディスパッチならそちらの host から取る
    private static func remoteHostNames(project: TestProject, profile: String) throws -> [String] {
        if let groups = try DeviceHostRunner.plan(
            project: project, profileName: profile, explicitHost: nil, deviceFilter: []) {
            return ApiRemoteCompat.remoteHostLabels(planGroups: groups, autoDispatchHost: nil)
        }
        let dispatch = try? resolveEffectiveHostDispatch(
            explicitHost: nil, profile: profile, project: project.name,
            requireMachineHost: true, warn: { _ in })
        return ApiRemoteCompat.remoteHostLabels(planGroups: nil, autoDispatchHost: dispatch?.rawHost)
    }

    private static func localDirty(repoRoot: URL?) -> Bool {
        guard let repoRoot,
              let result = try? Shell.run(["git", "-C", repoRoot.path, "status", "--porcelain"]),
              result.status == 0 else { return false }
        return !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 判定不能(repoRoot/revision が採れない)なら published 扱い(revisionIsPublished と同じ
    /// fail-open 方針。ここで拡張のダイアログを誤って出す理由にしない)
    private static func published(repoRoot: URL?, revision: String?) -> Bool {
        guard let repoRoot, let revision else { return true }
        return revisionIsPublished(repoRoot: repoRoot, revision: revision)
    }
}

/// リモートホスト集合を求める純粋関数(I/O 抜き。`Tests/FleetestTests/ApiRemoteCompatTests.swift` 対象)
enum ApiRemoteCompat {
    /// `DeviceHostRunner.plan` の groups があれば、その中の**リモート**(host != nil)のラベルを
    /// 出現順・重複除去で返す。groups が nil(単一機械)なら `autoDispatchHost` を高々1件返す
    static func remoteHostLabels(planGroups: [DeviceHostRunner.Group]?, autoDispatchHost: String?) -> [String] {
        guard let planGroups else {
            return autoDispatchHost.map { [$0] } ?? []
        }
        var seen = Set<String>()
        var result: [String] = []
        for group in planGroups {
            guard let host = group.host, !seen.contains(host) else { continue }
            seen.insert(host)
            result.append(host)
        }
        return result
    }
}

/// 省略可能なフィールドは JSON 上で "null" を明示する(ApiScenarioInfo と同方針 —— 外部ツール側で
/// キー欠落と null を区別せず扱えるよう、synthesized Encodable の encodeIfPresent(キー省略)は使わない)
private struct RemoteCompatHostJSON: Encodable {
    let name: String
    let sshTarget: String
    let reachable: Bool
    let revision: String?
    let revisionCompatible: Bool?
    /// `RevisionRelation.rawValue`。revisionCompatible == false かつ published(未 push でない)かつ
    /// local/remote 両 rev が取れているときだけ non-nil(§18.3 規則1)。後方互換フィールドなので
    /// ProtocolVersion は上げない
    let revisionRelation: String?
    let toolchain: String?
    let toolchainCompatible: Bool?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case name, sshTarget, reachable, revision, revisionCompatible, revisionRelation,
             toolchain, toolchainCompatible, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(sshTarget, forKey: .sshTarget)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(revision, forKey: .revision)
        try container.encode(revisionCompatible, forKey: .revisionCompatible)
        try container.encode(revisionRelation, forKey: .revisionRelation)
        try container.encode(toolchain, forKey: .toolchain)
        try container.encode(toolchainCompatible, forKey: .toolchainCompatible)
        try container.encode(error, forKey: .error)
    }
}

private struct RemoteCompatOutput: Encodable {
    let hosts: [RemoteCompatHostJSON]
    let localDirty: Bool
    let localRevision: String?
    let revisionPublished: Bool

    private enum CodingKeys: String, CodingKey {
        case hosts, localDirty, localRevision, revisionPublished
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hosts, forKey: .hosts)
        try container.encode(localDirty, forKey: .localDirty)
        try container.encode(localRevision, forKey: .localRevision)
        try container.encode(revisionPublished, forKey: .revisionPublished)
    }
}
