// VSCode拡張向け: 使われていない XCUITest/in-app ブリッジを起動し直し、xcresult の結果の束を孤児にする
// (`fleetest api restart-bridge`)。孤児になった束は `BridgeLauncher.sweepOrphanResultBundles` が
// 次の供給の入口で無条件に消すので、ここでは止めて供給し直すだけでよい。
// **デバイス本体は起動も停止もしない**(ブリッジだけ)。iOS だけ(Android のブリッジは常駐 APK で、
// 起動ごとの結果の束を持たない = 起動し直す対象が無い)。
// NDJSON は start-device と同じ log*/finished。判定・撃つ側の候補選定(VSCode 拡張)は
// 同期相手 vscode-fleetest/src/monitorBridgeLogRotation.ts。

import ArgumentParser
import FTAndroid
import FTBridgeClient
import FTCore
import Foundation

struct ApiRestartBridgeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart-bridge",
        abstract: "Rebuild the bridge for one iOS device without starting or stopping the device"
            + " itself, orphaning its xcresult result bundle so the retention sweep reclaims it"
            + " (NDJSON: log* -> finished on stdout; diagnostics on stderr only; exit code 1 when"
            + " ok:false)")

    @Option(help: "Logical device name (a name under ios in the run profiles)")
    var name: String

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Run profile name (when given, the device is looked up in that profile; otherwise in every run profile)")
    var profile: String?

    @Option(name: .customLong("device-machine"),
            help: "Only match devices assigned to this machine (\"local\" or a registered host name). Set by the caller on the other end of ssh")
    var deviceMachine: String?

    func run() async throws {
        try await ApiDeviceOperation.run(
            name: name, project: project, profile: profile, deviceMachine: deviceMachine,
            subcommand: "restart-bridge"
        ) { spec, platform, log in
            try Self.requireIOS(platform: platform)
            let repoRoot = try RepoRoot.find()
            try await Self.restart(spec: spec, repoRoot: repoRoot, log: log)
        }
    }

    /// Android は対象外(純粋関数・テスト用)
    static func requireIOS(platform: String) throws {
        guard platform == "ios" else { throw RestartBridgeError.androidNotSupported }
    }

    /// **①使用中なら断る ②そのデバイスの XCUITest ランナーだけを止める(in-app ブリッジ・他のデバイス・
    /// 他のポートは巻き込まない = 注入したアプリを起こし直さない)
    /// ③供給し直す**。①②の鍵・UDID 解決は `DeviceBooter.shutdownOne` と同じ引き方
    /// (`leaseKey` / `resolvedPhysicalIOSUDID`)——生きた lease を見落とすと使用中の run の
    /// ブリッジを黙って起動し直してしまう
    static func restart(spec: DeviceSpec, repoRoot: URL,
                        log: @escaping @Sendable (String) -> Void) async throws {
        var leaseKeys = [DeviceBooter.leaseKey(spec: spec, platform: "ios")].compactMap { $0 }
        var resolvedPhysicalUDID: String?
        if spec.isPhysical {
            let devices = (try? IOSPhysicalDeviceCatalog.devices()) ?? []
            resolvedPhysicalUDID = DeviceBooter.resolvedPhysicalIOSUDID(spec: spec, in: devices)
            if let resolved = resolvedPhysicalUDID, !leaseKeys.contains(resolved) {
                leaseKeys.append(resolved)
            }
        }
        if let refusal = DeviceBooter.deviceInUseRefusal(
            deviceName: spec.name, keys: leaseKeys, force: false, offersForce: false,
            leaseStateDir: repoRoot.appendingPathComponent(".fleetest")) {
            throw RestartBridgeError.inUse(refusal)
        }

        let udid: String
        if spec.isPhysical {
            guard let resolved = resolvedPhysicalUDID ?? spec.udid else {
                throw RestartBridgeError.noUDID(spec.name)
            }
            udid = resolved
        } else {
            udid = try SimulatorCatalog.resolve(spec: spec, in: SimulatorCatalog.devices()).udid
        }

        let stoppedPorts = BridgeLauncher.stopRunnersMatching(udid: udid, repoRoot: repoRoot)
        for port in stoppedPorts {
            log("→ \(spec.name): stopped the bridge (port \(port)) to rotate its xcresult log")
        }
        if stoppedPorts.isEmpty {
            log("✔ \(spec.name): no running bridge found on this device — provisioning a fresh one")
        }
        _ = try await BridgeProvisioner(repoRoot: repoRoot).provision(devices: [(spec.name, spec)], log: log)
    }
}

enum RestartBridgeError: Error, LocalizedError, Equatable {
    case androidNotSupported
    case inUse(String)
    case noUDID(String)

    var errorDescription: String? {
        switch self {
        case .androidNotSupported:
            return "restart-bridge is for iOS only (the Android bridge is a resident APK with no"
                + " per-launch result bundle to rotate; use bridge down --port or stop-device instead)"
        case .inUse(let message):
            return message
        case .noUDID(let name):
            return "could not resolve a UDID for \(name)"
        }
    }
}
