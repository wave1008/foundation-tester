// simctl list devices -j のパースと、マシンプロファイルのデバイス指定
// (simulator 名+OS / UDID)→ シミュレータ実体(UDID)の解決。
// CLI(BridgeProvisioner)から使う。

import Foundation
import FTCore

public struct SimDeviceInfo: Sendable, Hashable, Identifiable {
    public let udid: String
    public let name: String
    /// "iOS 27.0" 形式
    public let os: String
    public let booted: Bool
    public var id: String { udid }

    public init(udid: String, name: String, os: String, booted: Bool) {
        self.udid = udid
        self.name = name
        self.os = os
        self.booted = booted
    }
}

public enum SimulatorCatalogError: Error, LocalizedError {
    case simctlFailed(String)
    case udidNotFound(String)
    case nameNotFound(name: String, os: String?, available: [String])

    public var errorDescription: String? {
        switch self {
        case .simctlFailed(let detail):
            return "simctl list devices に失敗しました: \(detail)"
        case .udidNotFound(let udid):
            return "UDID のシミュレータが見つかりません: \(udid)(xcrun simctl list devices で確認)"
        case .nameNotFound(let name, let os, let available):
            let osText = os.map { "(\($0))" } ?? ""
            return "シミュレータが見つかりません: \(name)\(osText)"
                + "(利用可能: \(available.isEmpty ? "なし" : available.joined(separator: ", ")))"
        }
    }
}

public enum SimulatorCatalog {

    /// 利用可能な iOS シミュレータ一覧(起動中 → OS 降順 → 名前順)
    public static func devices() throws -> [SimDeviceInfo] {
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
        return found.sorted {
            if $0.booted != $1.booted { return $0.booted }
            if $0.os != $1.os { return $0.os > $1.os }
            return $0.name < $1.name
        }
    }

    /// UDID 指定が最優先、次に simulator 名+OS(候補複数なら起動中→OS降順の先頭)
    public static func resolve(spec: DeviceSpec,
                               in devices: [SimDeviceInfo]) throws -> SimDeviceInfo {
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
