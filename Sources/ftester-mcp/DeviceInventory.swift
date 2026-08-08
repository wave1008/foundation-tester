// ft_list_devices / ft_list_apps の本文を組み立てる材料。MCPServer.swift(配線は別担当)から呼ぶ。
//
// **マシンプロファイルを前提にできない**: .claude/skills/ftester-mcp/SKILL.md の導線(MCP だけ
// 入れる受け手)は machines/ を一つも持たない。devicesText はプロファイルが解決できないときも
// 素のカタログ(SimulatorCatalog / AndroidSerialResolver)へフォールバックし、**絶対に throw しない**
// (失敗も文章として本文に書く)。
//
// ApiListDevicesCommand.swift の ApiMonitorCommand.determineStates は ftester 実行ターゲットに
// 閉じていて ftester-mcp からは見えないため使わない。ここでは同種の判定を軽量に再実装する
// (登録デバイスの疎通は 1 台ずつ試し、1 台の失敗で他を落とさない)。

import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

enum DeviceInventory {

    /// 整形前の 1 デバイス分。フィールドは line(_:) が文へ組む
    struct Row: Equatable {
        let name: String
        let platform: String   // "ios" / "android"
        let identifier: String?  // iOS=udid, Android=serial
        let running: Bool
        let physical: Bool
        let registered: Bool
        let port: UInt16?      // 稼働中の iOS ブリッジのポート(判明時のみ)
    }

    struct ResolvedMachine {
        let name: String
        let profile: MachineProfile
    }

    // MARK: - ft_list_devices

    static func devicesText(project: String?, profile: String?, platform: String?) async -> String {
        guard platform == nil || platform == "ios" || platform == "android" else {
            return "unknown platform: \(platform ?? "") (expected \"ios\" or \"android\")"
        }
        let wantsIOS = platform == nil || platform == "ios"
        let wantsAndroid = platform == nil || platform == "android"

        let lookup = resolveMachine(project: project, profile: profile)
        if case .resolved(let machine) = lookup {
            var rows: [Row] = []
            if wantsIOS { rows += await iosMachineRows(specs: machine.profile.ios?.devices ?? []) }
            if wantsAndroid { rows += androidMachineRows(specs: machine.profile.android?.devices ?? []) }
            guard !rows.isEmpty else {
                return "machine profile \"\(machine.name)\" defines no \(platform ?? "ios/android") devices."
            }
            return (["machine profile: \(machine.name)"] + rows.map(line)).joined(separator: "\n")
        }

        var rows: [Row] = []
        if wantsIOS { rows += await iosFallbackRows() }
        if wantsAndroid { rows += androidFallbackRows() }
        let header = fallbackHeader(reason: lookup.reason)
        guard !rows.isEmpty else { return header + "\nNone found." }
        return ([header] + rows.map(line)).joined(separator: "\n")
    }

    /// マシンプロファイルを使えないときの見出し(純粋関数・テスト用)。
    /// **理由を必ず載せる** —— 設定の壊れ(登録マシン名とプロファイル名の不一致など)を黙って
    /// フォールバックで隠すと、受け手は自分の profiles/ が死んでいることに気づけない
    static func fallbackHeader(reason: String) -> String {
        "Not using a machine profile (\(reason))."
            + " Listing devices that are currently booted/connected instead:"
    }

    /// 1 デバイス分を 1 行へ組む(純粋関数・テスト用)
    static func line(_ row: Row) -> String {
        var parts = [row.platform, row.physical ? "physical" : "virtual",
                     row.registered ? "registered" : "unregistered",
                     row.running ? "running" : "not running"]
        if let identifier = row.identifier {
            parts.append((row.platform == "ios" ? "udid " : "serial ") + identifier)
        }
        if let port = row.port {
            parts.append("bridge port \(port)")
        }
        return "- \(row.name) (\(parts.joined(separator: ", ")))"
    }

    enum MachineLookup {
        case resolved(ResolvedMachine)
        case unavailable(String)

        var reason: String {
            if case .unavailable(let reason) = self { return reason }
            return ""
        }
    }

    private static func resolveMachine(project: String?, profile: String?) -> MachineLookup {
        let testProject: TestProject
        do {
            testProject = try ScenarioHost.project(named: project)
        } catch {
            return .unavailable(describe(error))
        }
        let machine: (name: String, auto: Bool)
        do {
            machine = try ProfileResolver.determineMachine(
                project: testProject, registered: LocalConfig.currentMachineName(),
                runProfileName: profile)
        } catch {
            return .unavailable(describe(error))
        }
        let url = testProject.machinesDir.appendingPathComponent("\(machine.name).json")
        guard let data = try? Data(contentsOf: url) else {
            return .unavailable("machine profile \"\(machine.name)\" is not in"
                + " \(testProject.name)/profiles/machines/")
        }
        guard let decoded = try? JSONDecoder().decode(MachineProfile.self, from: data) else {
            return .unavailable("machine profile \"\(machine.name)\" could not be decoded")
        }
        return .resolved(ResolvedMachine(name: machine.name, profile: decoded))
    }

    private static func describe(_ error: Error) -> String {
        ((error as? LocalizedError)?.errorDescription ?? "\(error)")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - iOS

    private static func iosMachineRows(specs: [DeviceSpec]) async -> [Row] {
        guard !specs.isEmpty else { return [] }
        let simDevices = (try? SimulatorCatalog.devices()) ?? []
        let physicalDevices = specs.contains(where: \.isPhysical)
            ? ((try? IOSPhysicalDeviceCatalog.devices()) ?? []) : []
        let livePorts = await liveIOSBridgePorts()
        return specs.map { iosRow(spec: $0, simDevices: simDevices, physicalDevices: physicalDevices,
                                  livePorts: livePorts) }
    }

    /// 純粋関数(テスト用): spec と実測カタログから 1 行分を組む
    static func iosRow(spec: DeviceSpec, simDevices: [SimDeviceInfo],
                       physicalDevices: [IOSPhysicalDeviceInfo],
                       livePorts: [String: UInt16]) -> Row {
        if spec.isPhysical {
            let udid = spec.udid ?? ""
            let match = physicalDevices.first { $0.udid == udid || $0.deviceCtlIdentifier == udid }
            let running = match?.connected ?? false
            return Row(name: spec.name, platform: "ios", identifier: spec.udid ?? match?.udid,
                      running: running, physical: true, registered: true,
                      port: running ? livePorts[match?.name ?? spec.name] : nil)
        }
        let match: SimDeviceInfo?
        if let udid = spec.udid, !udid.isEmpty {
            match = simDevices.first { $0.udid == udid }
        } else {
            let name = spec.simulator ?? "iPhone 17 Pro"
            let os = spec.os.map { $0.hasPrefix("iOS") ? $0 : "iOS \($0)" }
            match = simDevices.first { $0.name == name && (os == nil || $0.os == os) }
        }
        let running = match?.booted ?? false
        return Row(name: spec.name, platform: "ios", identifier: match?.udid ?? spec.udid,
                  running: running, physical: false, registered: true,
                  port: running ? livePorts[match?.name ?? spec.name] : nil)
    }

    private static func iosFallbackRows() async -> [Row] {
        let booted = ((try? SimulatorCatalog.devices()) ?? []).filter(\.booted)
        guard !booted.isEmpty else { return [] }
        let livePorts = await liveIOSBridgePorts()
        return booted.map { device in
            Row(name: device.name, platform: "ios", identifier: device.udid, running: true,
               physical: false, registered: false, port: livePorts[device.name])
        }
    }

    /// 生きている iOS ブリッジのポートをシミュレータ名で引けるようにする。1 台への疎通失敗は
    /// BridgeDiscovery.scan が内部で握って次へ進む(呼び出し側は空 dict を受け取るだけ)
    private static func liveIOSBridgePorts() async -> [String: UInt16] {
        let found = await BridgeDiscovery.scan(excluding: 0, repoRoot: nil)
        var result: [String: UInt16] = [:]
        for entry in found { result[entry.device] = entry.port }
        return result
    }

    // MARK: - Android

    private static func androidMachineRows(specs: [DeviceSpec]) -> [Row] {
        guard !specs.isEmpty else { return [] }
        let connectedSerials = AndroidSerialResolver.connectedSerials()
        let connectedDevices = AndroidSerialResolver.describe(serials: connectedSerials)
        return specs.map { androidRow(spec: $0, connectedDevices: connectedDevices) }
    }

    /// 純粋関数(テスト用): spec と接続中デバイス一覧から 1 行分を組む
    static func androidRow(spec: DeviceSpec, connectedDevices: [AndroidSerialResolver.Device]) -> Row {
        if spec.isPhysical {
            let serial = spec.serial ?? ""
            let running = connectedDevices.contains { $0.serial == serial }
            return Row(name: spec.name, platform: "android", identifier: serial.isEmpty ? nil : serial,
                      running: running, physical: true, registered: true, port: nil)
        }
        if let avd = spec.avd, let match = connectedDevices.first(where: { $0.avd == avd }) {
            return Row(name: spec.name, platform: "android", identifier: match.serial, running: true,
                      physical: false, registered: true, port: nil)
        }
        return Row(name: spec.name, platform: "android", identifier: nil, running: false,
                  physical: false, registered: true, port: nil)
    }

    private static func androidFallbackRows() -> [Row] {
        let serials = AndroidSerialResolver.connectedSerials()
        guard !serials.isEmpty else { return [] }
        return AndroidSerialResolver.describe(serials: serials).map { device in
            Row(name: device.avd ?? device.serial, platform: "android", identifier: device.serial,
               running: true, physical: device.avd == nil, registered: false, port: nil)
        }
    }

    // MARK: - ft_list_apps

    /// **宛先の解決はしない** —— どのデバイスを見るかは MCPServer の driver(_:) が一手に決める
    /// (ここで BridgeClient を建て直すと profile 指定が既定ポートへ逸れる)
    static func appsText(apps: [SimulatorAppCatalog.App]) -> String {
        let userApps = apps.filter(\.isUser)
        return renderAppLines(userApps: userApps.map { "\($0.id)  \($0.name)" },
                              systemCount: apps.count - userApps.count)
    }

    /// `pm list packages -3` は端末側で既に user アプリ(third-party)へ絞られているので
    /// system の総数は分からない
    static func appsText(packages: [String]) -> String {
        renderAppLines(userApps: packages, systemCount: nil)
    }

    /// 純粋関数(テスト用): user アプリの行 + system 件数を本文へ組む
    static func renderAppLines(userApps: [String], systemCount: Int?) -> String {
        var lines: [String]
        if userApps.isEmpty {
            lines = ["0 user apps installed."]
        } else {
            lines = ["\(userApps.count) user app(s):"] + userApps
        }
        if let systemCount, systemCount > 0 {
            lines.append("(\(systemCount) system app(s) omitted)")
        }
        return lines.joined(separator: "\n")
    }
}
