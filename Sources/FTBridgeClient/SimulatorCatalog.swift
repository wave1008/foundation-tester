// simctl list devices -j のパースと、マシンプロファイルのデバイス指定
// (simulator 名+OS / UDID)→ シミュレータ実体(UDID)の解決。
// CLI(BridgeProvisioner)から使う。

import Foundation
import FTCore
import FTCoreSimShim

/// 解決済みの iOS デバイス実体。シミュレータと実機の両方を表す(physical で区別)。
/// 実機は SimulatorCatalog ではなく IOSPhysicalDeviceCatalog が埋める
public struct SimDeviceInfo: Sendable, Hashable, Identifiable {
    public let udid: String
    public let name: String
    /// "iOS 27.0" 形式
    public let os: String
    public let booted: Bool
    /// 実機か。simctl / CoreSimulator を叩く経路はすべてこれで分岐する
    public let physical: Bool
    /// USB 接続か(devicectl の transportType == "wired")。実機のトランスポート選択に使う。
    /// **WiFi のみの端末に iproxy の USB トンネルは張れない**(シミュレータは常に true 扱い)
    public let wired: Bool
    public var id: String { udid }

    public init(udid: String, name: String, os: String, booted: Bool, physical: Bool = false,
                wired: Bool = true) {
        self.udid = udid
        self.name = name
        self.os = os
        self.booted = booted
        self.physical = physical
        self.wired = wired
    }
}

public enum SimulatorCatalogError: Error, LocalizedError {
    case simctlFailed(String)
    case udidNotFound(String)
    case nameNotFound(name: String, os: String?, available: [String])

    public var errorDescription: String? {
        switch self {
        case .simctlFailed(let detail):
            return "simctl list devices failed: \(detail)"
        case .udidNotFound(let udid):
            return "no simulator with that UDID: \(udid) (check xcrun simctl list devices)"
        case .nameNotFound(let name, let os, let available):
            let osText = os.map { "(\($0))" } ?? ""
            return "simulator not found: \(name)\(osText)"
                + " (available: \(available.isEmpty ? "none" : available.joined(separator: ", ")))"
        }
    }
}

public enum SimulatorCatalog {

    /// 利用可能な iOS シミュレータ一覧(起動中 → OS 降順 → 名前順)。
    /// CoreSimulator 直叩き(FTCoreSimShim。列挙 6ms vs simctl 567ms・2026-07-25 実測)優先、
    /// 利用不能なら simctl フォールバック。殺しスイッチ: FT_SIMULATOR_CONTROL=simctl
    public static func devices() throws -> [SimDeviceInfo] {
        if ProcessInfo.processInfo.environment["FT_SIMULATOR_CONTROL"] != "simctl",
           let viaShim = devicesViaCoreSimulator() {
            return viaShim
        }
        return try devicesViaSimctl()
    }

    /// CoreSimulator 経由(nil = シム利用不能。私有 API のセレクタ欠落等)。テストが等価性検証に使う
    static func devicesViaCoreSimulator() -> [SimDeviceInfo]? {
        guard let raw = FTCoreSimListDevices() else { return nil }
        let found = raw.compactMap { entry -> SimDeviceInfo? in
            guard let udid = entry["udid"] as? String,
                  let name = entry["name"] as? String,
                  let os = entry["os"] as? String,
                  let booted = entry["booted"] as? Bool else { return nil }
            return SimDeviceInfo(udid: udid, name: name, os: os, booted: booted)
        }
        return sorted(found)
    }

    /// simctl 経由(従来経路)。テストが等価性検証に使う
    static func devicesViaSimctl() throws -> [SimDeviceInfo] {
        let result = try Shell.run(["xcrun", "simctl", "list", "devices", "-j"])
        guard result.status == 0,
              let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]] else {
            throw SimulatorCatalogError.simctlFailed(result.tail)
        }
        var found: [SimDeviceInfo] = []
        for (runtime, list) in runtimes {
            // "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS 27.0"
            let os = runtime
                .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                .replacingOccurrences(of: "-", with: ".")
                .replacingOccurrences(of: "iOS.", with: "iOS ")
            guard os.hasPrefix("iOS") else { continue }
            for device in list {
                guard (device["isAvailable"] as? Bool) == true,
                      let udid = device["udid"] as? String,
                      let name = device["name"] as? String else { continue }
                let booted = (device["state"] as? String) == "Booted"
                found.append(SimDeviceInfo(udid: udid, name: name, os: os, booted: booted))
            }
        }
        return sorted(found)
    }

    /// 起動中 → OS 降順 → 名前順(resolve が「先頭=最良候補」に依存する契約)
    private static func sorted(_ devices: [SimDeviceInfo]) -> [SimDeviceInfo] {
        devices.sorted {
            if $0.booted != $1.booted { return $0.booted }
            if $0.os != $1.os { return $0.os > $1.os }
            return $0.name < $1.name
        }
    }

    /// UDID 指定が最優先、次に simulator 名+OS(候補複数なら起動中→OS降順の先頭)。
    /// kind=physical は devices(シミュレータ一覧)を見ず devicectl 側へ委譲する
    /// (呼び出し側は分岐を書かずに済む。実機は「常に booted」として扱う)
    public static func resolve(spec: DeviceSpec,
                               in devices: [SimDeviceInfo]) throws -> SimDeviceInfo {
        if spec.isPhysical {
            let device = try IOSPhysicalDeviceCatalog.resolve(
                spec: spec, in: IOSPhysicalDeviceCatalog.devices())
            return SimDeviceInfo(udid: device.udid, name: device.name, os: device.os,
                                 booted: true, physical: true,
                                 wired: device.transport == "wired")
        }
        if let udid = spec.udid {
            guard let device = devices.first(where: { $0.udid == udid }) else {
                throw SimulatorCatalogError.udidNotFound(udid)
            }
            return device
        }
        let name = spec.simulator ?? "iPhone 17 Pro"
        // "27.0" → "iOS 27.0" に正規化(プロファイルではどちらでも書ける)
        let os = spec.os.map { $0.hasPrefix("iOS") ? $0 : "iOS \($0)" }
        let candidates = devices.filter { device in
            device.name == name && (os == nil || device.os == os)
        }
        guard let best = candidates.first else {
            throw SimulatorCatalogError.nameNotFound(
                name: name, os: os,
                available: Array(Set(devices.map(\.name))).sorted())
        }
        return best  // devices は 起動中 → OS 降順 で並んでいる
    }
}
