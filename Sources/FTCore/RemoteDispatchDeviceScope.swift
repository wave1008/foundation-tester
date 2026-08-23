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

/// `--host H` に **明示の `--device <名前>`** が付いたとき(`--device-host` 無し)の扱い。
/// 同名の台が複数の機械にある混在プロファイルでは、名前だけを子へ渡すと**全機械ぶんの同名を拾い**、
/// 手元の UDID をランナー機で探して `no simulator with that UDID` で落ちる(受け手報告 2026-08-23:
/// local/M1Max/M1Ultra に同名の iPhone があるプロファイルで --device 1台 → Devices に3台並んだ)。
/// `--host` を付けたときの `--device` は**そのホストの台に限定**する(明示が勝つ規律と同じ向き)
public enum RemoteDispatchExplicitDeviceScope: Equatable, Sendable {
    /// 全デバイスが host 未指定 = 名前をそのまま渡す(受け側が自分の台として解釈する)
    case passThrough
    /// 混在: 名前は全部そのホストにある → `--device-host <targetHost>` を付けて渡す
    case pinned
    /// 混在だが、要求した名前のうち `missing` はそのホストの台に無い(`available` はそのホストの台)。
    /// 遠い失敗(向こうで UDID 不明)にせず、ここで候補を列挙して止める
    case notOnHost(missing: [String], available: [String])

    public static func resolve(targetHost: String, requested: [String],
                               devices: [RunDeviceHost]) -> RemoteDispatchExplicitDeviceScope {
        guard !devices.isEmpty,
              !devices.allSatisfy({ MachineHostDispatch.normalize($0.host) == nil })
        else { return .passThrough }
        let available = devices.filter { DeviceHostGrouping.display($0.host) == targetHost }.map(\.name)
        let availableSet = Set(available)
        let missing = requested.filter { !availableSet.contains($0) }
        return missing.isEmpty ? .pinned : .notOnHost(missing: missing, available: available)
    }
}
