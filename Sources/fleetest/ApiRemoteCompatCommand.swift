// ApiRemoteCompatCommand.swift
// `fleetest api remote-compat --project <P> --profile <X>`: 拡張の実行前チェック専用
// (人が読む表は `fleetest remote status`)。プロファイルのリモートホスト集合を求め、
// `RemoteStatusProbing`(RemoteCommands.swift。`remote status` と共有)で並列プローブし、
// JSON を1行 stdout へ出す。exit は常に 0 — ズレの有無は JSON で伝える契約(--project/--profile
// の解決エラーだけ非0)。

import ArgumentParser
import FTBridgeClient
import FTCore
import FTRemote
import Foundation

struct ApiRemoteCompatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote-compat",
        abstract: "Report git revision / toolchain compatibility of a run profile's remote runners,"
            + " for the extension's pre-run check (the human-readable table is `fleetest remote status`)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name")
    var profile: String

    @Option(name: .customLong("remote-dir"),
            help: ArgumentHelp("Runner-only base directory override for every host"
                + " (default: each machine registry entry, or ~/fleetest-runner)"))
    var remoteDir: String?

    func run() async throws {
        let testProject = try ScenarioHost.project(named: project)
        let machineNames = try Self.remoteHostNames(project: testProject, profile: profile)

        let repoRoot = try? RepoRoot.find()
        let localRevision = localGitRevision()
        let localDirty = Self.localDirty(repoRoot: repoRoot)
        let localToolchain = ToolchainFingerprint.current()
        let published = Self.published(repoRoot: repoRoot, revision: localRevision)

        var machines: [RemoteCompatMachineJSON?] = Array(repeating: nil, count: machineNames.count)
        var targets: [(index: Int, resolved: ResolvedRemoteHost)] = []
        for (index, name) in machineNames.enumerated() {
            do {
                let resolved = try RemoteHostResolver.resolve(rawHost: name, remoteDirOverride: remoteDir)
                targets.append((index, resolved))
            } catch {
                machines[index] = RemoteCompatMachineJSON(
                    machine: name, sshTarget: name, reachable: false, revision: nil,
                    revisionCompatible: nil, revisionRelation: nil, toolchain: nil, toolchainCompatible: nil,
                    toolchainAdvisory: nil, xcodeSelectionError: nil, error: error.localizedDescription)
            }
        }

        let probed: [Int: HostRow] = await withTaskGroup(of: (Int, HostRow).self) { group in
            for entry in targets {
                group.addTask { (entry.index, await RemoteStatusProbing.probe(entry.resolved, wantFM: false, wantRuntime: false)) }
            }
            var collected: [Int: HostRow] = [:]
            for await (index, row) in group { collected[index] = row }
            return collected
        }
        for (index, row) in probed {
            let report = HostReport(row: row, localRevision: localRevision, localToolchain: localToolchain)
            let revisionCompatible = report.revisionCompatible
            let remoteRevision = report.status?.revision
            // published のときだけ向きを出す(未 push は align 案内が誤誘導になる。checkCompatibility と同じ規律)
            let relation: RevisionRelation? = {
                guard revisionCompatible == false, published,
                      let localRevision, let remoteRevision, let repoRoot else { return nil }
                return revisionRelation(repoRoot: repoRoot, localRevision: localRevision, remoteRevision: remoteRevision)
            }()
            machines[index] = RemoteCompatMachineJSON(
                machine: machineNames[index], sshTarget: report.sshTarget, reachable: report.reachable,
                revision: remoteRevision,
                revisionCompatible: revisionCompatible,
                revisionRelation: relation?.rawValue,
                toolchain: report.status?.toolchain,
                toolchainCompatible: report.toolchainCompatible,
                toolchainAdvisory: report.toolchainAdvisory,
                xcodeSelectionError: report.xcodeSelectionRefusalReason,
                error: report.detail)
        }

        let output = RemoteCompatOutput(
            machines: machines.compactMap { $0 }, localDirty: localDirty, localRevision: localRevision,
            revisionPublished: published)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(output)
        ConsoleOut.out(String(data: data, encoding: .utf8)!)
    }

    /// この実行プロファイルが使うリモートマシンのラベル一覧(登録名。docs/remote-runner.md §13 —
    /// devices[].machine は登録名でしか書けない契約)。機械が2つ以上にまたがっていれば
    /// DeviceMachineRunner の分割計画から、単一機械の自動ディスパッチならその機械を取る
    private static func remoteHostNames(project: TestProject, profile: String) throws -> [String] {
        if let groups = try DeviceMachineRunner.plan(
            project: project, profileName: profile, explicitHost: nil, deviceFilter: [],
            disabledMachines: MachineEnablement.disabledMachines(config: LocalConfig.load())) {
            return ApiRemoteCompat.remoteMachineLabels(planGroups: groups, autoDispatchMachine: nil)
        }
        let dispatch = try? resolveEffectiveDispatchTarget(
        explicitTarget: nil, profile: profile, project: project.name,
            requireProfileMachine: true)
        return ApiRemoteCompat.remoteMachineLabels(planGroups: nil, autoDispatchMachine: dispatch?.rawTarget)
    }

    private static func localDirty(repoRoot: URL?) -> Bool {
        guard let repoRoot,
              let result = try? Shell.run(["git", "-C", repoRoot.path, "status", "--porcelain"]),
              result.status == 0 else { return false }
        // TestProjects/ 配下だけの変更は rsync で届くので dirty に数えない(判定は 1 箇所)
        return RemoteRunDispatcher.hasUncommittedToolChanges(porcelain: result.output)
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
    /// `DeviceMachineRunner.plan` の groups があれば、その中の**リモート**(host != nil)のラベルを
    /// 出現順・重複除去で返す。groups が nil(単一機械)なら `autoDispatchMachine` を高々1件返す
    static func remoteMachineLabels(planGroups: [DeviceMachineRunner.Group]?,
                                    autoDispatchMachine: String?) -> [String] {
        guard let planGroups else {
            return autoDispatchMachine.map { [$0] } ?? []
        }
        var seen = Set<String>()
        var result: [String] = []
        for group in planGroups {
            guard let machine = group.machine, !seen.contains(machine) else { continue }
            seen.insert(machine)
            result.append(machine)
        }
        return result
    }
}

/// 省略可能なフィールドは JSON 上で "null" を明示する(ApiScenarioInfo と同方針 —— 外部ツール側で
/// キー欠落と null を区別せず扱えるよう、synthesized Encodable の encodeIfPresent(キー省略)は使わない)
private struct RemoteCompatMachineJSON: Encodable {
    /// 登録簿のマシン名(エイリアス)。sshTarget は解決後のホスト名 / IP で別物
    let machine: String
    let sshTarget: String
    let reachable: Bool
    let revision: String?
    let revisionCompatible: Bool?
    /// `RevisionRelation.rawValue`。revisionCompatible == false かつ published(未 push でない)かつ
    /// local/remote 両 rev が取れているときだけ non-nil(§18.3 規則1)。後方互換フィールドなので
    /// ProtocolVersion は上げない
    let revisionRelation: String?
    let toolchain: String?
    /// blocking で止まるか(advisory = ベータ seed だけの差は true のまま)
    let toolchainCompatible: Bool?
    /// toolchainCompatible が true でも advisory があれば1文。無ければ null
    let toolchainAdvisory: String?
    /// ランナーで使う Xcode を決められなかったときの理由(候補一覧つき)。**非 null なら実行は止まる**
    /// (`toolchainCompatible` も false になる)。`remote status --json` と同じ鍵
    let xcodeSelectionError: String?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case machine, sshTarget, reachable, revision, revisionCompatible, revisionRelation,
             toolchain, toolchainCompatible, toolchainAdvisory, xcodeSelectionError, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machine, forKey: .machine)
        try container.encode(sshTarget, forKey: .sshTarget)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(revision, forKey: .revision)
        try container.encode(revisionCompatible, forKey: .revisionCompatible)
        try container.encode(revisionRelation, forKey: .revisionRelation)
        try container.encode(toolchain, forKey: .toolchain)
        try container.encode(toolchainCompatible, forKey: .toolchainCompatible)
        try container.encode(toolchainAdvisory, forKey: .toolchainAdvisory)
        try container.encode(xcodeSelectionError, forKey: .xcodeSelectionError)
        try container.encode(error, forKey: .error)
    }
}

private struct RemoteCompatOutput: Encodable {
    let machines: [RemoteCompatMachineJSON]
    let localDirty: Bool
    let localRevision: String?
    let revisionPublished: Bool

    private enum CodingKeys: String, CodingKey {
        case machines, localDirty, localRevision, revisionPublished
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machines, forKey: .machines)
        try container.encode(localDirty, forKey: .localDirty)
        try container.encode(localRevision, forKey: .localRevision)
        try container.encode(revisionPublished, forKey: .revisionPublished)
    }
}
