// マシン混在プロファイルを 1 マシンへ丸ごと送らないための絞り込み判定(純粋ロジック)。
// 丸ごと送ると、受け側の「local」枠が発行元のデバイスに解決され、存在しない台を掴む
// (2026-08-18 実害: remote setup の verify)。--device/--device-machine を既に持つ呼び出し
// (ApiRunMachineFanout / DeviceMachineRunner / FleetRunner の子)はこの判定を通さない。

import Foundation

public enum RemoteDispatchDeviceScope: Equatable, Sendable {
    /// 全デバイスが machine 未指定 = 従来どおりプロファイル丸ごと(受け側が自分の台として解釈する)
    case wholeProfile
    /// マシン混在: このマシン担当分だけを --device/--device-machine で渡す(プロファイルの記載順)
    case filtered(deviceNames: [String])
    /// マシン混在だが対象マシンの担当が1台も無い(available はデバイスのマシン表示名・出現順)
    case noneForMachine(available: [String])

    public static func resolve(targetMachine: String, devices: [RunDeviceMachine]) -> RemoteDispatchDeviceScope {
        guard !devices.isEmpty else { return .wholeProfile }
        if devices.allSatisfy({ MachineDispatch.normalize($0.machine) == nil }) { return .wholeProfile }
        let matching = devices.filter { DeviceMachineGrouping.display($0.machine) == targetMachine }
        if !matching.isEmpty { return .filtered(deviceNames: matching.map(\.name)) }
        var seen = Set<String>()
        var machines: [String] = []
        for device in devices {
            let machine = DeviceMachineGrouping.display(device.machine)
            if seen.insert(machine).inserted { machines.append(machine) }
        }
        return .noneForMachine(available: machines)
    }
}

/// `--machine M` に **明示の `--device <名前>`** が付いたとき(`--device-machine` 無し)の扱い。
/// 同名の台が複数の機械にある混在プロファイルでは、名前だけを子へ渡すと**全機械ぶんの同名を拾い**、
/// 手元の UDID をランナー機で探して `no simulator with that UDID` で落ちる(受け手報告 2026-08-23:
/// local/M1Max/M1Ultra に同名の iPhone があるプロファイルで --device 1台 → Devices に3台並んだ)。
/// `--machine` を付けたときの `--device` は**そのマシンの台に限定**する(明示が勝つ規律と同じ向き)
public enum RemoteDispatchExplicitDeviceScope: Equatable, Sendable {
    /// 全デバイスが machine 未指定 = 名前をそのまま渡す(受け側が自分の台として解釈する)
    case passThrough
    /// 混在: 名前は全部そのマシンにある → `--device-machine <targetMachine>` を付けて渡す
    case pinned
    /// 混在だが、要求した名前のうち `missing` はそのマシンの台に無い(`available` はそのマシンの台)。
    /// 遠い失敗(向こうで UDID 不明)にせず、ここで候補を列挙して止める
    case notOnMachine(missing: [String], available: [String])

    public static func resolve(targetMachine: String, requested: [String],
                               devices: [RunDeviceMachine]) -> RemoteDispatchExplicitDeviceScope {
        guard !devices.isEmpty,
              !devices.allSatisfy({ MachineDispatch.normalize($0.machine) == nil })
        else { return .passThrough }
        let available = devices.filter { DeviceMachineGrouping.display($0.machine) == targetMachine }.map(\.name)
        let availableSet = Set(available)
        let missing = requested.filter { !availableSet.contains($0) }
        return missing.isEmpty ? .pinned : .notOnMachine(missing: missing, available: available)
    }
}
