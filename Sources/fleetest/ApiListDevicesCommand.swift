// VSCode拡張のライブ操作パネル(デバイス選択)向け: 実行プロファイルの全デバイスと
// 現在状態を 1 回だけ判定して JSON で stdout に出力する(fleetest api list-devices)。
// 状態判定は ApiMonitorCommand.determineStates(常駐監視のポーリングロジック)をそのまま
// 再利用する(挙動を分岐させないため。private を外して共有した MonitorTarget /
// DeviceRuntimeState も同様)。stdout には結果 1 行の JSON だけを出す(診断は stderr のみ)。
//
// udid: iOS は解決済み UDID(シミュレータ / 実機とも。ApiLiveCommand --udid のブリッジ自動起動に
// 使う)。resolve 失敗・Android は null。
// kind: "virtual"(シミュレータ/エミュレータ)/ "physical"(実機)。実機は録画・画面配信が
// できない等で扱いが変わるため消費側が判別できるようにする(追加フィールド=後方互換)。
// registered: false はどの実行プロファイルにも無い起動中デバイス(ApiMonitorCommand.determineStates
// の includeUnregistered と同じ合成。--profile 指定時は合成しない=false)。
// 対向: vscode-fleetest/src/liveModel.ts

import ArgumentParser
import Foundation
import FTCore

struct ApiListDevices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-devices",
        abstract: "Evaluate every device on this machine (from the run profiles) and its current state once, and print it"
            + " as JSON on stdout (diagnostics on stderr only)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name (when given, only that profile's enabled devices; otherwise the devices of every run profile)")
    var profile: String?

    func run() async throws {
        let testProject = try ScenarioHost.project(named: project)
        // --profile を渡されたら**そのプロファイルの enabled の台だけ**(モニターと同じ RunProfileScope)。
        // 無ければ全実行プロファイルの和(MachineInventory。単発なので実在での決着はしない)
        let scoped: DeviceRoster
        if let profile {
            scoped = try RunProfileScope.roster(project: testProject, runProfileName: profile)
        } else {
            let sources = MachineInventory.loadAllNamed(project: testProject) { logStderr($0) }
            let machines = sources.flatMap { DeviceMachineGrouping.entries(roster: $0.profile) }
                .compactMap(\.machine)
            let merged = MachineInventory.merge(sources: sources, registry: machines, existsLocally: nil)
            for conflict in merged.conflicts { logStderr("→ \(conflict.message)") }
            scoped = MachineInventory.mergedProfile(merged.entries)
        }

        // **このコマンドは「この機械で操作できるデバイス」を答える**(ライブ操作の対象選択に使う)。
        // 別の機械のデバイスはここからは触れないので落とす —— 出すと選べてしまい、操作は必ず失敗する。
        // モニターは表示だけなのでリモートも出す(そちらは machine をタイルに出して区別する)
        let allDevices = DeviceMachineGrouping.entries(roster: scoped)
        let localDevices = allDevices.filter { $0.machine == nil }
        if localDevices.count < allDevices.count {
            logStderr("→ Skipped \(allDevices.count - localDevices.count) device(s) that live on"
                + " another machine (they cannot be driven from here)")
        }
        let targets = localDevices.map { MonitorTarget(platform: $0.platform, spec: $0.spec) }
        guard !targets.isEmpty || profile == nil else {
            throw ValidationError("run profile \(profile ?? "") has no enabled devices on this machine")
        }

        // ApiMonitorCommand と同じ判定ロジックを 1 回だけ実行する(debounce なし。
        // 常駐監視と違い単発呼び出しなので、ばたつき抑制は不要かつ状態を持てない)。
        // --profile 指定時は監視対象がそのプロファイル参照デバイスに絞られている意図のため
        // 未登録デバイスは合成しない(ApiMonitorCommand.run の同じ条件と揃える)
        // 単発なので衝突の警告はその場で出す(常駐監視だけが変化を見て絞る)
        let (states, skipped) = await ApiMonitorCommand.determineStates(
            targets: targets, includeUnregistered: profile == nil)
        for message in skipped { logStderr(message) }

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
            project: testProject.name, devices: devices)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        ConsoleOut.out(String(data: data, encoding: .utf8)!)
    }

    private func logStderr(_ message: String) {
        ConsoleOut.err(message)
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

/// fleetest api list-devices の出力全体(同期相手: vscode-fleetest/src/liveModel.ts)
private struct ApiListDevicesOutput: Encodable {
    let project: String
    let devices: [ApiDeviceEntry]
}
