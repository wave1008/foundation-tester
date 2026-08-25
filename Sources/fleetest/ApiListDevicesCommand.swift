// VSCode拡張のライブ操作パネル(デバイス選択)向け: マシンプロファイルの全デバイスと
// 現在状態を 1 回だけ判定して JSON で stdout に出力する(fleetest api list-devices)。
// 状態判定は ApiMonitorCommand.determineStates(常駐監視のポーリングロジック)をそのまま
// 再利用する(挙動を分岐させないため。private を外して共有した MonitorTarget /
// DeviceRuntimeState も同様)。stdout には結果 1 行の JSON だけを出す(診断は stderr のみ)。
//
// udid: iOS は解決済み UDID(シミュレータ / 実機とも。ApiLiveCommand --udid のブリッジ自動起動に
// 使う)。resolve 失敗・Android は null。
// kind: "virtual"(シミュレータ/エミュレータ)/ "physical"(実機)。実機は録画・画面配信が
// できない等で扱いが変わるため消費側が判別できるようにする(追加フィールド=後方互換)。
// registered: false はマシンプロファイル未記載の起動中デバイス(ApiMonitorCommand.determineStates
// の includeUnregistered と同じ合成。--profile 指定時は従来どおり合成しない=false)。
// 対向: vscode-fleetest/src/liveModel.ts

import ArgumentParser
import Foundation
import FTCore

struct ApiListDevices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-devices",
        abstract: "Evaluate every device in the machine profile and its current state once, and print it"
            + " as JSON on stdout (diagnostics on stderr only)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name, used to resolve the machine. When given, that profile's machine wins; otherwise FT_MACHINE, the registered machine, or the only entry in machines/")
    var profile: String?

    func run() async throws {
        let testProject = try ScenarioHost.project(named: project)
        // runProfileName を渡さないと machines/ 複数時に「マシン名が未登録」で落ちる
        // (ApiDeviceCommands.swift と同経路。対向: monitorLiveController.ts)
        let machine = try ProfileResolver.determineMachine(
            project: testProject,
            runProfileName: profile)
        if machine.auto {
            logStderr("→ Using machine profile \(machine.name) automatically (it is the only one in machines/)")
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

        // --profile を渡されたら**そのプロファイルが参照するデバイスだけ**に絞る(モニターと
        // 同じ RunProfileScope を通す。以前は「マシンの解決」にしか使っておらず、同じ --profile が
        // モニターとここで別の集合を指していた)
        var scoped = machineProfile
        if let profile {
            scoped = try RunProfileScope.filteredMachineProfile(
                project: testProject, machineName: machine.name, machineProfile: machineProfile,
                runProfileName: profile, warn: { logStderr($0) })
        }

        // **このコマンドは「この機械で操作できるデバイス」を答える**(ライブ操作の対象選択に使う)。
        // 別の機械のデバイスはここからは触れないので落とす —— 出すと選べてしまい、操作は必ず失敗する。
        // モニターは表示だけなのでリモートも出す(そちらは machineHost をタイルに出して区別する)
        let allDevices = (scoped.ios?.devices ?? []).map { (platform: "ios", spec: $0) }
            + (scoped.android?.devices ?? []).map { (platform: "android", spec: $0) }
        let localDevices = allDevices.filter {
            DeviceHostGrouping.effectiveHost(device: $0.spec, machineHost: scoped.host) == nil
        }
        if localDevices.count < allDevices.count {
            logStderr("→ Skipped \(allDevices.count - localDevices.count) device(s) that live on"
                + " another machine (they cannot be driven from here)")
        }
        let targets = localDevices.map { MonitorTarget(platform: $0.platform, spec: $0.spec) }
        guard !targets.isEmpty else {
            throw ValidationError("machine profile \(machine.name) defines no devices"
                + " on this machine\(profile.map { " for run profile \($0)" } ?? "")")
        }

        // ApiMonitorCommand と同じ判定ロジックを 1 回だけ実行する(debounce なし。
        // 常駐監視と違い単発呼び出しなので、ばたつき抑制は不要かつ状態を持てない)。
        // --profile 指定時は監視対象がそのプロファイル参照デバイスに絞られている意図のため
        // 未登録デバイスは合成しない(ApiMonitorCommand.run の同じ条件と揃える)
        let states = await ApiMonitorCommand.determineStates(targets: targets, includeUnregistered: profile == nil)

        let devices = states.map { state in
            ApiDeviceEntry(
                name: state.target.name,
                platform: state.target.platform,
                state: state.state,
                detail: state.detail,
                // iOS: 接続中ブリッジの実効ポート(ライブ操作パネルが --port 付きで api live を
                // 呼ぶために必要)。未接続なら DeviceSpec.port(固定指定があれば)、無ければ null。
                // Android: 実行時解決した serial(未起動なら null)
                port: state.target.platform == "ios"
                    ? (state.iosPort ?? state.target.spec.port) : nil,
                serial: state.target.platform == "android" ? state.androidSerial : nil,
                udid: state.target.platform == "ios" ? state.iosUdid : nil,
                kind: state.target.spec.isPhysical ? "physical" : "virtual",
                registered: state.target.registered)
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

/// fleetest api list-devices の 1 デバイス分。省略可能フィールドは明示的に null を encode する
/// (ApiScenarioInfo と同方針)
private struct ApiDeviceEntry: Encodable {
    let name: String
    let platform: String
    let state: String
    let detail: String
    let port: UInt16?
    let serial: String?
    let udid: String?
    let kind: String
    let registered: Bool

    private enum CodingKeys: String, CodingKey {
        case name, platform, state, detail, port, serial, udid, kind, registered
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(platform, forKey: .platform)
        try container.encode(state, forKey: .state)
        try container.encode(detail, forKey: .detail)
        try container.encode(port, forKey: .port)
        try container.encode(serial, forKey: .serial)
        try container.encode(udid, forKey: .udid)
        try container.encode(kind, forKey: .kind)
        try container.encode(registered, forKey: .registered)
    }
}

/// fleetest api list-devices の出力全体
private struct ApiListDevicesOutput: Encodable {
    let project: String
    let machine: String
    let devices: [ApiDeviceEntry]
}
