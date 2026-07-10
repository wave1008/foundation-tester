// ApiListDevicesCommand.swift
// VSCode拡張のライブ操作パネル(デバイス選択)向け: マシンプロファイルの全デバイスと
// 現在状態を 1 回だけ判定して JSON で stdout に出力する(ftester api list-devices)。
// 状態判定は ApiMonitorCommand.determineStates(常駐監視のポーリングロジック)をそのまま
// 再利用する(挙動を分岐させないため。private を外して共有した MonitorTarget /
// DeviceRuntimeState も同様)。stdout には結果 1 行の JSON だけを出す(診断は stderr のみ)。

import ArgumentParser
import Foundation
import FTCore

struct ApiListDevices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-devices",
        abstract: "マシンプロファイルの全デバイスと現在状態を1回判定してJSONでstdoutに出力する"
            + "(診断は stderr のみ)")

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    func run() async throws {
        let testProject = try ScenarioHost.project(named: project)
        let machine = try ProfileResolver.determineMachine(
            project: testProject, registered: LocalConfig.currentMachineName())
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

        var targets = (machineProfile.ios?.devices ?? []).map {
            MonitorTarget(platform: "ios", spec: $0)
        }
        targets += (machineProfile.android?.devices ?? []).map {
            MonitorTarget(platform: "android", spec: $0)
        }
        guard !targets.isEmpty else {
            throw ValidationError("マシンプロファイル \(machine.name) にデバイスが定義されていません")
        }

        // ApiMonitorCommand と同じ判定ロジックを 1 回だけ実行する(debounce なし。
        // 常駐監視と違い単発呼び出しなので、ばたつき抑制は不要かつ状態を持てない)
        let states = await ApiMonitorCommand.determineStates(targets: targets)

        let devices = states.map { state in
            ApiDeviceEntry(
                name: state.target.name,
                platform: state.target.platform,
                state: state.state,
                detail: state.detail,
                // iOS: 接続中ブリッジの実効ポート(determineStates が /status 照合で解決した
                // DeviceRuntimeState.iosPort。ライブ操作パネルが --port 付きで api live 系を
                // 呼ぶために必要)。未接続なら DeviceSpec.port(固定指定があれば)、それも無ければ null。
                // Android: 実行時解決した serial(未起動なら null)
                port: state.target.platform == "ios"
                    ? (state.iosPort ?? state.target.spec.port) : nil,
                serial: state.target.platform == "android" ? state.androidSerial : nil)
        }

        let output = ApiListDevicesOutput(
            project: testProject.name, machine: machine.name, devices: devices)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }

    private func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// ftester api list-devices の 1 デバイス分。省略可能フィールドは明示的に null を encode する
/// (ApiScenarioInfo と同方針)
private struct ApiDeviceEntry: Encodable {
    let name: String
    let platform: String
    let state: String
    let detail: String
    let port: UInt16?
    let serial: String?

    private enum CodingKeys: String, CodingKey {
        case name, platform, state, detail, port, serial
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(platform, forKey: .platform)
        try container.encode(state, forKey: .state)
        try container.encode(detail, forKey: .detail)
        try container.encode(port, forKey: .port)
        try container.encode(serial, forKey: .serial)
    }
}

/// ftester api list-devices の出力全体
private struct ApiListDevicesOutput: Encodable {
    let project: String
    let machine: String
    let devices: [ApiDeviceEntry]
}
