// iOS 実機(kind: physical)の列挙。`xcrun devicectl list devices --json-output -` の
// result.devices をパースする。シミュレータ側の SimulatorCatalog と対になる。
//   - devicectl の JSON 出力は「バージョン付きで安定」とドキュメント上保証されている唯一の出力
//     (標準出力の人間向け表示は不安定なので使わない)
//   - hardwareProperties/deviceProperties/connectionProperties は deprecated。properties 辞書を
//     優先し、旧 Xcode 向けに deprecated 側もフォールバックで読む
//   - CoreSimulator が生成する「シミュレータのエントリ」も同じ一覧に混ざるため
//     reality == "simulated" を必ず除外する

import Foundation
import FTCore

public struct IOSPhysicalDeviceInfo: Sendable, Hashable, Identifiable {
    /// ハードウェア UDID("00008130-001819863E60001C" 形式)。マシンプロファイルの udid に書く値。
    /// **devicectl の identifier(別の UUID)ではない**: xcodebuild の -destination id= が
    /// 受け付けるのはこちらだけ(devicectl --device はどちらでも通る。2026-07-25 実機で確認)
    public let udid: String
    /// devicectl の identifier。list devices の Identifier 列に出る値(照合用に保持)
    public let deviceCtlIdentifier: String
    public let name: String
    /// "iOS 18.5" 形式(SimDeviceInfo.os と表記を揃える)
    public let os: String
    /// 現在ホストから到達できるか(USB/WiFi いずれか)
    public let connected: Bool
    /// "wired" / "localNetwork" など devicectl の transportType 生値
    public let transport: String
    /// 機種名(marketingName。例 "iPhone 15 Pro")。取得できなければ空文字
    public let model: String
    public var id: String { udid }

    public init(udid: String, name: String, os: String, connected: Bool, transport: String,
                deviceCtlIdentifier: String? = nil, model: String = "") {
        self.udid = udid
        self.name = name
        self.os = os
        self.connected = connected
        self.transport = transport
        self.deviceCtlIdentifier = deviceCtlIdentifier ?? udid
        self.model = model
    }
}

public enum IOSPhysicalDeviceCatalogError: Error, LocalizedError {
    case devicectlFailed(String)
    case notFound(udid: String, available: [IOSPhysicalDeviceInfo])
    case notConnected(udid: String, name: String)

    public var errorDescription: String? {
        switch self {
        case .devicectlFailed(let detail):
            return "xcrun devicectl list devices failed: \(detail)"
        case .notFound(let udid, let available):
            let list = available.isEmpty ? "none"
                : available.map { "\($0.name)(\($0.udid))" }.joined(separator: ", ")
            return "no physical iOS device with that UDID: \(udid) (recognised devices: \(list)). "
                + "Check the USB connection, \"Trust This Computer\" and Developer Mode"
        case .notConnected(let udid, let name):
            return "the physical iOS device \(name) (\(udid)) is registered but not currently connected"
                + " (re-plug the USB cable, or for WiFi make sure it is on the same network)"
        }
    }
}

public enum IOSPhysicalDeviceCatalog {

    /// 接続状態に関わらず devicectl が知っている実機すべて(接続中 → 名前順)
    public static func devices() throws -> [IOSPhysicalDeviceInfo] {
        // devicectl は稀に応答しないため時限化(締切ループが無効化するのを防ぐ)
        let result = try Shell.run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", "-", "-q"], timeout: 30)
        guard result.status == 0,
              let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]] else {
            throw IOSPhysicalDeviceCatalogError.devicectlFailed(result.tail)
        }
        return devices.compactMap(parse).sorted {
            if $0.connected != $1.connected { return $0.connected }
            return $0.name < $1.name
        }
    }

    /// 実機 1 台分のパース(シミュレータ・非 iOS・UDID 欠落は nil で捨てる)
    static func parse(_ entry: [String: Any]) -> IOSPhysicalDeviceInfo? {
        let properties = entry["properties"] as? [String: Any]
        let hardware = (properties?["hardware"] as? [String: Any])
            ?? (entry["hardwareProperties"] as? [String: Any]) ?? [:]
        // reality(CoreDevice の DeviceReality)は physical / simulated / virtual(=VM)の三値だが、
        // **実機は値を出さずキーごと省略する**(Xcode 27 beta 4 実測 2026-07-25: 68 台中
        // 67 台が "simulated"、実機 1 台はキー欠落)。よって "physical" 一致で拾ってはいけない
        // (実機が 1 台も見えなくなる)。「simulated 以外」で弾くこと。
        // virtual(VM)も通るが iOS の VM は存在せず platform 条件と併せて実害はない
        guard (hardware["reality"] as? String) != "simulated",
              (hardware["platform"] as? String) == "iOS" else { return nil }
        let identifier = entry["identifier"] as? String
        // udid(ハードウェア UDID)を正にする。identifier は別の UUID で、xcodebuild の
        // -destination id= はこれを受け付けない
        guard let udid = hardware["udid"] as? String ?? identifier else { return nil }

        let state = (properties?["state"] as? [String: Any])
            ?? (entry["deviceProperties"] as? [String: Any]) ?? [:]
        let name = (state["name"] as? String)
            ?? (hardware["marketingName"] as? String) ?? udid

        // properties 側は構造体、deprecated 側は "18.5" の素の文字列
        let version = ((properties?["software"] as? [String: Any])?["osVersionNumber"]
            as? [String: Any])?["stringValue"] as? String
            ?? (entry["deviceProperties"] as? [String: Any])?["osVersionNumber"] as? String

        let connection = (properties?["connection"] as? [String: Any])
            ?? (entry["connectionProperties"] as? [String: Any]) ?? [:]
        let transport = (connection["transportType"] as? String) ?? "unknown"

        // **到達性は connection.state / tunnelState だけで決める**。
        // `pairingState` と `bootState` は**一度ペアリングした端末には繋がっていなくても残り続ける**
        // ので信号にならない(実測 2026-08-28・Xcode 27.0・2台で実機6台分: 接続中の wired 2台が
        // state="connected"、手元に無い localNetwork 4台が state="disconnected"。pairingState は
        // 6台とも "paired"、bootState も6台とも "booted")。
        //
        // 以前は「未接続の実機は list devices にそもそも出てこない」を前提に paired/booted も
        // 真としていたが、**devicectl は接続が切れてもペアリング済みの端末を列挙し続ける** ——
        // その結果、判定が「devicectl が知っている = 到達可能」= 恒真になり、モニターの
        // 「起動中のデバイス」に手元に無い iPhone が「未起動」タイルとして並んでいた。
        //
        // 2026-07-25(Xcode 27 beta 4)には USB 接続中でも state="disconnected" と出た記録がある。
        // 27.0 では再現しない。**もし将来のベータでまた嘘をつくなら、症状は
        // `IOSPhysicalDeviceCatalogError.notConnected` で明示的に落ちる**(黙って誤った緑には
        // ならない)ので、そのときは信号を足す
        return IOSPhysicalDeviceInfo(
            udid: udid,
            name: name,
            os: version.map { "iOS \($0)" } ?? "iOS",
            connected: (connection["state"] as? String) == "connected"
                || (connection["tunnelState"] as? String) == "connected",
            transport: transport,
            deviceCtlIdentifier: identifier,
            model: (hardware["marketingName"] as? String) ?? "")
    }

    /// マシンプロファイルの udid → 実機。未接続はエラー(この先の xcodebuild が必ず失敗するため、
    /// 分かりやすい段階で止める)
    public static func resolve(spec: DeviceSpec,
                               in devices: [IOSPhysicalDeviceInfo]) throws -> IOSPhysicalDeviceInfo {
        let udid = spec.udid ?? ""
        // ユーザーが devicectl の Identifier 列(別 UUID)を書いていても解決する
        guard let device = devices.first(where: {
            $0.udid == udid || $0.deviceCtlIdentifier == udid
        }) else {
            throw IOSPhysicalDeviceCatalogError.notFound(udid: udid, available: devices)
        }
        guard device.connected else {
            throw IOSPhysicalDeviceCatalogError.notConnected(udid: udid, name: device.name)
        }
        return device
    }
}
