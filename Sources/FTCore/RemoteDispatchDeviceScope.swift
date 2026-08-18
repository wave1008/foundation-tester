// ホスト混在プロファイルを 1 ホストへ丸ごと送らないための絞り込み判定(純粋ロジック)。
// 丸ごと送ると、受け側の「local」枠が発行元のデバイスに解決され、存在しない台を掴む
// (2026-08-18 実害: remote setup の verify)。--device/--device-host を既に持つ呼び出し
// (ApiRunHostFanout / DeviceHostRunner / FleetRunner の子)はこの判定を通さない。

import Foundation

public enum RemoteDispatchDeviceScope: Equatable, Sendable {
    /// 全デバイスが host 未指定 = 従来どおりプロファイル丸ごと(受け側が自分の台として解釈する)
    case wholeProfile
    /// ホスト混在: このホスト担当分だけを --device/--device-host で渡す(プロファイルの記載順)
    case filtered(deviceNames: [String])
    /// ホスト混在だが対象ホストの担当が1台も無い(available はデバイスのホスト表示名・出現順)
    case noneForHost(available: [String])

    public static func resolve(targetHost: String, devices: [RunDeviceHost]) -> RemoteDispatchDeviceScope {
        guard !devices.isEmpty else { return .wholeProfile }
        if devices.allSatisfy({ MachineHostDispatch.normalize($0.host) == nil }) { return .wholeProfile }
        let matching = devices.filter { DeviceHostGrouping.display($0.host) == targetHost }
        if !matching.isEmpty { return .filtered(deviceNames: matching.map(\.name)) }
        var seen = Set<String>()
        var hosts: [String] = []
        for device in devices {
            let host = DeviceHostGrouping.display(device.host)
            if seen.insert(host).inserted { hosts.append(host) }
        }
        return .noneForHost(available: hosts)
    }
}
