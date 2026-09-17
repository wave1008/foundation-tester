// simctl list devices -j のパースと、実行プロファイルのデバイス指定
// (デバイス名+OS / UDID)→ シミュレータ実体(UDID)の解決。
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
    case ambiguousName(name: String, os: String, udids: [String])

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
        case .ambiguousName(let name, let os, let udids):
            return "several simulators are named \(name) (\(os)): \(udids.joined(separator: ", "))"
                + " — name one by its UDID instead"
        }
    }
}

public enum SimulatorCatalog {

    /// simctl の締切(秒)。`api monitor` の既定周期 2 秒のループから呼ばれるので、CoreSimulatorService
    /// が凍った simctl に無期限に握らせない。値はモニターが simctl screenshot に置く 15 秒
    /// (ApiMonitorCommand.simctlScreenshot。実測 1.7 秒の混雑時の伸び)と同じ。
    /// 尽きると Shell が子を kill して `ShellError.timedOut` を投げる = 呼び出し側は simctl 失敗と
    /// 同じ扱い(モニターは `try?` で空一覧、供給はコマンド名入りのエラーで落ちる)
    public static let simctlTimeoutSeconds: Double = 15

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
        let result = try Shell.run(["xcrun", "simctl", "list", "devices", "-j"],
                                   timeout: simctlTimeoutSeconds)
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

    /// UDID → 機種名(Xcode の Model = device type 名)。登録時に `model` を控えるためだけに使う
    /// (simctl を2表ぶん読むので、監視の周期経路からは呼ばない)。読めなければ空
    public static func modelNamesByUDID() -> [String: String] {
        guard let result = try? Shell.run(["xcrun", "simctl", "list", "-j", "devicetypes", "devices"],
                                          timeout: simctlTimeoutSeconds),
              result.status == 0,
              let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return modelNames(simctlJSON: json)
    }

    /// modelNamesByUDID の解析部(純粋関数)
    static func modelNames(simctlJSON json: [String: Any]) -> [String: String] {
        var typeNames: [String: String] = [:]
        for type in (json["devicetypes"] as? [[String: Any]]) ?? [] {
            if let id = type["identifier"] as? String, let name = type["name"] as? String {
                typeNames[id] = name
            }
        }
        var result: [String: String] = [:]
        for list in ((json["devices"] as? [String: [[String: Any]]]) ?? [:]).values {
            for device in list {
                guard let udid = device["udid"] as? String,
                      let typeID = device["deviceTypeIdentifier"] as? String,
                      let name = typeNames[typeID] else { continue }
                result[udid] = name
            }
        }
        return result
    }

    /// 起動中 → OS 降順 → 名前順(resolve が「先頭=最良候補」に依存する契約)
    private static func sorted(_ devices: [SimDeviceInfo]) -> [SimDeviceInfo] {
        devices.sorted {
            if $0.booted != $1.booted { return $0.booted }
            if $0.os != $1.os { return $0.os > $1.os }
            return $0.name < $1.name
        }
    }

    /// UDID 指定が最優先、次に name(= シミュレータの名前)+OS(候補複数なら起動中→OS降順の先頭)。
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
        let name = spec.name
        // simctl の表記("iOS 27.0")で比べる。CLI の `--os 27.0` のような接頭辞なしも受ける
        let os = spec.osVersion.map { $0.hasPrefix("iOS") ? $0 : "iOS \($0)" }
        let candidates = devices.filter { device in
            device.name == name && (os == nil || device.os == os)
        }
        guard let best = candidates.first else {
            throw SimulatorCatalogError.nameNotFound(
                name: name, os: os,
                available: Array(Set(devices.map(\.name))).sorted())
        }
        // **起動状態も OS も同じ同名の台が複数なら規則では決まらない** —— 黙って1台目を選ぶと、
        // 同名の別の台(プロファイルが UDID で指している方)を起動して使う(実例: 同名が2台ある機で
        // `bridge up --device <名前>` が別の1台を起こした)。起動中の1台・新しい OS を選ぶ規則は残す
        let tied = candidates.filter { $0.booted == best.booted && $0.os == best.os }
        guard tied.count == 1 else {
            throw SimulatorCatalogError.ambiguousName(name: name, os: best.os, udids: tied.map(\.udid))
        }
        return best  // devices は 起動中 → OS 降順 で並んでいる
    }

    /// 純関数: UDID がシミュレータ一覧・実機一覧のどちらに居るかを返す。**形状では判別できない**
    /// (実機 UDID は 25 文字型・旧 40 桁 hex 型があり、シミュレータの「36 文字・ダッシュ5分割」
    /// 判定を外れる。BridgeLauncher.physical のコメント参照)。どちらにも無ければ nil
    /// (呼び出し側が既定へ倒せるよう断定しない)
    /// **実機一覧は遅延**(シミュレータで当たれば devicectl を引かない)。この形は
    /// BridgeClient.resolveTarget(named:simulators:physicalDevices:) と同じで、
    /// 「シミュレータ優先」の短絡を判定側に1つだけ持たせるため
    static func isPhysical(udid: String, simulators: [SimDeviceInfo],
                           physicalDevices: () -> [IOSPhysicalDeviceInfo]) -> Bool? {
        if simulators.contains(where: { $0.udid == udid }) { return false }
        if physicalDevices().contains(where: { $0.udid == udid || $0.deviceCtlIdentifier == udid }) {
            return true
        }
        return nil
    }

    /// I/O 版。一覧の取得自体が失敗したときも nil(判別できない)
    public static func isPhysical(udid: String) -> Bool? {
        isPhysical(udid: udid, simulators: (try? devices()) ?? [],
                   physicalDevices: { (try? IOSPhysicalDeviceCatalog.devices()) ?? [] })
    }

    /// エラーの最初の1行だけを理由として使う(スタックトレース等の残りは捨てる)。
    /// shutdownObservation と lookupUDID(udid:) が共有する
    static func firstLineReason(_ error: Error) -> String {
        let reason = error.localizedDescription
            .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return reason.isEmpty ? String(describing: error) : reason
    }

    /// `isPhysical(udid:simulators:physicalDevices:)` の4値版。「一覧を読んだがどちらにも
    /// 載っていない」と「一覧そのものが読めなかった(負荷下の simctl タイムアウト等)」を
    /// 混同しない —— `isPhysical` は両方を nil に潰しており、MCP の「no running bridge」文言が
    /// 読み取り失敗を「載っていない」と誤って断定していた
    public enum UDIDLookup: Equatable, Sendable {
        case simulator
        case physical
        case notFound
        /// 一覧の読み取り自体が失敗した(理由の1行)
        case unreadable(String)
    }

    /// 純関数。**実機一覧は遅延**(シミュレータで当たれば devicectl を引かない。isPhysical と同じ理由)
    static func lookupUDID(
        udid: String, simulators: Result<[SimDeviceInfo], Error>,
        physicalDevices: () -> Result<[IOSPhysicalDeviceInfo], Error>
    ) -> UDIDLookup {
        switch simulators {
        case .failure(let error):
            return .unreadable(firstLineReason(error))
        case .success(let devices):
            if devices.contains(where: { $0.udid == udid }) { return .simulator }
        }
        switch physicalDevices() {
        case .failure(let error):
            return .unreadable(firstLineReason(error))
        case .success(let devices):
            if devices.contains(where: { $0.udid == udid || $0.deviceCtlIdentifier == udid }) {
                return .physical
            }
            return .notFound
        }
    }

    /// I/O 版
    public static func lookupUDID(udid: String) -> UDIDLookup {
        lookupUDID(udid: udid, simulators: Result { try devices() },
                   physicalDevices: { Result { try IOSPhysicalDeviceCatalog.devices() } })
    }
}

/// 停止を確かめるための読み。**一覧が読めないことを「止まった」と読まない**
/// (`(try? devices())?.contains(...) ?? false` の形は、読めないと停止を確認できないまま成功を名乗る)
public enum SimulatorShutdownObservation: Equatable, Sendable {
    case stopped
    case stillBooted
    /// 一覧を読めなかった(理由の1行)。呼び手は成功とも失敗とも言わず「確認できない」と言う
    case unreadable(String)
}

extension SimulatorCatalog {
    /// udid: nil なら「起動中の台が1台も無いか」、指定ならその台だけを見る(一覧から消えた台は停止扱い)
    public static func shutdownObservation(
        _ read: Result<[SimDeviceInfo], Error>, udid: String?
    ) -> SimulatorShutdownObservation {
        switch read {
        case .failure(let error):
            return .unreadable(SimulatorCatalog.firstLineReason(error))
        case .success(let devices):
            let booted: Bool
            if let udid {
                booted = devices.first(where: { $0.udid == udid })?.booted ?? false
            } else {
                booted = devices.contains(where: \.booted)
            }
            return booted ? .stillBooted : .stopped
        }
    }

    public static func shutdownObservation(udid: String?) -> SimulatorShutdownObservation {
        shutdownObservation(Result { try devices() }, udid: udid)
    }
}
