// VSCode拡張のライブ操作パネル向け: マシンプロファイル記載のデバイス1台の起動・停止
// (ftester api device-up / device-down)。起動・停止の実装(DeviceBooter/BridgeProvisioner)は
// DevicesCommand(ftester devices)と共通。stdout には NDJSON(log* → finished)だけを出す
// (診断は stderr のみ。ok:false のときは exit code 1)。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct ApiDeviceUp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-up",
        abstract: "マシンプロファイル記載のデバイス1台を起動する(NDJSON: log* → finished を"
            + "stdout に出力。診断は stderr のみ。ok:false のときは exit code 1)")

    @Option(help: "デバイスの論理名(マシンプロファイルの ios/android どちらかの name)")
    var name: String

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "実行プロファイル名(machine 解決に使う。指定時はそのプロファイルの machine を最優先。省略時は FT_MACHINE / 登録マシン / machines が 1 つならそれ)")
    var profile: String?

    func run() async throws {
        try await ApiDeviceOperation.run(name: name, project: project, profile: profile) { spec, platform, log in
            try await DeviceBooter.bootOne(spec: spec, platform: platform, log: log)
            // iOS はブリッジも供給する(稼働中ブリッジがあれば再利用。供給しないと画面が取れず
            // 「起動済み(ブリッジ未接続)」のままになる)
            if platform == "ios" {
                let root = try RepoRoot.find()
                _ = try await BridgeProvisioner(repoRoot: root)
                    .provision(devices: [(spec.name, spec)], log: log)
            }
        }
    }
}

struct ApiDeviceDown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-down",
        abstract: "マシンプロファイル記載のデバイス1台を停止する(NDJSON: log* → finished を"
            + "stdout に出力。診断は stderr のみ。ok:false のときは exit code 1)")

    @Option(help: "デバイスの論理名(マシンプロファイルの ios/android どちらかの name)")
    var name: String

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "実行プロファイル名(machine 解決に使う。指定時はそのプロファイルの machine を最優先。省略時は FT_MACHINE / 登録マシン / machines が 1 つならそれ)")
    var profile: String?

    func run() async throws {
        try await ApiDeviceOperation.run(name: name, project: project, profile: profile) { spec, platform, log in
            // iOS はシミュレータ停止前に稼働ブリッジも探して停止する(ゾンビ化防止。
            // BridgeProvisioner.provision の失敗時後始末と対)。repoRoot 未検出時は nil のまま
            // 渡しブリッジ停止をスキップして simctl shutdown のみ行う
            let repoRoot = platform == "ios" ? try? RepoRoot.find() : nil
            try await DeviceBooter.shutdownOne(
                spec: spec, platform: platform, repoRoot: repoRoot, log: log)
        }
    }
}

/// ftester api device-up / device-down 共通の実行ロジック
/// (マシンプロファイル読み込み・--name 解決・NDJSON ストリーミング・エラー処理)
private enum ApiDeviceOperation {
    static func run(
        name: String, project: String?, profile: String?,
        body: @escaping @Sendable (
            DeviceSpec, String, @escaping @Sendable (String) -> Void
        ) async throws -> Void
    ) async throws {
        // finished 到達を読み手が確実に検知できるよう、log イベントもすぐ流す
        setvbuf(stdout, nil, _IOLBF, 0)

        let testProject = try ScenarioHost.project(named: project)
        // runProfileName を渡すと determineMachine が実行プロファイルの machine を最優先で解決する。
        // これが無いと machines/ 複数時に「マシン名が未登録」で落ちる(DevicesCommand.Up と同経路)。
        let machine = try ProfileResolver.determineMachine(
            project: testProject, registered: LocalConfig.currentMachineName(),
            runProfileName: profile)
        if machine.auto {
            logStderr("→ マシンプロファイル自動採用: \(machine.name)(machines/ が 1 つのため)")
        }
        let machineURL = testProject.machinesDir.appendingPathComponent("\(machine.name).json")
        guard FileManager.default.fileExists(atPath: machineURL.path) else {
            throw ProfileError.machineProfileNotFound(
                machine: machine.name,
                available: ProfileResolver.machineNames(project: testProject))
        }
        let machineProfile: MachineProfile
        do {
            machineProfile = try JSONDecoder().decode(
                MachineProfile.self, from: Data(contentsOf: machineURL))
        } catch {
            throw ProfileError.decodeFailed(machineURL, detail: "\(error)")
        }

        guard let found = findDevice(name: name, in: machineProfile) else {
            emitFinished(ok: false, error: "デバイスが見つかりません: \(name)(マシン \(machine.name))")
            throw ExitCode(1)
        }

        do {
            try await body(found.spec, found.platform) { message in emitLog(message) }
            emitFinished(ok: true, error: nil)
        } catch {
            emitFinished(ok: false, error: error.localizedDescription)
            throw ExitCode(1)
        }
    }

    /// --name をマシンプロファイルの ios/android 両方から検索する
    private static func findDevice(
        name: String, in machine: MachineProfile
    ) -> (spec: DeviceSpec, platform: String)? {
        if let spec = (machine.ios?.devices ?? []).first(where: { $0.name == name }) {
            return (spec, "ios")
        }
        if let spec = (machine.android?.devices ?? []).first(where: { $0.name == name }) {
            return (spec, "android")
        }
        return nil
    }

    private static func emitLog(_ message: String) {
        emitLine(ApiDeviceLogEvent(message: message))
    }

    private static func emitFinished(ok: Bool, error: String?) {
        emitLine(ApiDeviceFinishedEvent(ok: ok, error: error))
    }

    private static func emitLine<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }

    private static func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// 進捗ログ 1 行分(DeviceBooter/BridgeProvisioner の log コールバック由来)
private struct ApiDeviceLogEvent: Encodable {
    let kind = "log"
    let message: String
}

/// 末尾イベント。error は省略可能フィールドとして明示的に null を encode する
/// (ApiScenarioInfo と同方針)
private struct ApiDeviceFinishedEvent: Encodable {
    let kind = "finished"
    let ok: Bool
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case kind, ok, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
    }
}
