// 実行プロファイルの iOS デバイス指定 → 稼働ブリッジの照合・不足分の起動。
// 稼働中ブリッジのスキャン(/status)と .ftester/bridge-<port>.pid を唯一の状態源として、
// 同時に動く他プロセスのブリッジ管理と競合しないポート割当を行う。

import Foundation
import FTCore

public struct ProvisionedIOSDevice: Sendable {
    /// マシンプロファイル上の論理名(例: メイン機)
    public let name: String
    public let udid: String
    public let simulatorName: String
    public let port: UInt16
}

public enum BridgeProvisionerError: Error, LocalizedError {
    case noFreePort(scanned: ClosedRange<UInt16>)
    /// waitUntilReady() が失敗した場合(後始末として起動済みプロセス/pidファイルは停止済み)
    case notReady(port: UInt16, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .noFreePort(let scanned):
            return "空きポートがありません(走査範囲: \(scanned.lowerBound)〜\(scanned.upperBound))"
        case .notReady(let port, let underlying):
            return "ブリッジが時間内に準備できませんでした(port \(port)): \(underlying)"
        }
    }
}

public struct BridgeProvisioner {
    let repoRoot: URL
    /// 稼働ブリッジのスキャン・自動採番の範囲(既定: 8123〜8154)
    let portRange: ClosedRange<UInt16>

    public init(repoRoot: URL,
                portRange: ClosedRange<UInt16> =
                    BridgeAPI.defaultPort...(BridgeAPI.defaultPort + 31)) {
        self.repoRoot = repoRoot
        self.portRange = portRange
    }

    /// 稼働中ブリッジ(シミュレータ UDID が一致)は再利用し、不足分は空きポートで起動する
    public func provision(devices: [(name: String, spec: DeviceSpec)],
                          log: @escaping (String) -> Void) async throws -> [ProvisionedIOSDevice] {
        let catalog = try SimulatorCatalog.devices()

        // 1. デバイス指定 → シミュレータ実体(UDID)
        var targets: [(name: String, spec: DeviceSpec, sim: SimDeviceInfo)] = []
        for (name, spec) in devices {
            let sim = try SimulatorCatalog.resolve(spec: spec, in: catalog)
            targets.append((name, spec, sim))
        }

        // 2. 稼働中ブリッジのスキャン(ポート → 接続先シミュレータ UDID。詳細は scanRunningBridges 参照)
        let running = await scanRunningBridges(catalog: catalog)
        if !running.isEmpty {
            let summary = running.keys.sorted().map(String.init).joined(separator: ", ")
            log("→ 稼働中ブリッジ: port \(summary)")
        }

        // 3. 照合と起動
        var provisioned: [ProvisionedIOSDevice] = []
        var usedPorts = Set(running.keys)
        for (name, spec, sim) in targets {
            if let port = running.first(where: { $0.value == sim.udid })?.key,
               !provisioned.contains(where: { $0.port == port }) {
                log("✅ \(name): 稼働中ブリッジを再利用(port \(port), \(sim.name))")
                provisioned.append(ProvisionedIOSDevice(
                    name: name, udid: sim.udid, simulatorName: sim.name, port: port))
                continue
            }

            let port = try assignPort(preferred: spec.port, used: &usedPorts)
            log("→ \(name): ブリッジ起動(port \(port), \(sim.name) \(sim.os))...")
            let launcher = BridgeLauncher(repoRoot: repoRoot, device: sim.udid, port: port)
            try await Task.detached(priority: .userInitiated) {
                try launcher.generateProjectIfNeeded()
                do {
                    try launcher.startDetached()
                } catch LauncherError.xctestrunNotFound {
                    // ビルド未実施の場合のみ build-for-testing(初回は数分かかる)
                    log("→ build-for-testing(初回は数分かかります)...")
                    try launcher.buildForTesting()
                    try launcher.startDetached()
                }
            }.value
            do {
                try await launcher.waitUntilReady()
            } catch {
                // 後始末せずに投げると assignPort がこのポートを使用中とみなし続け採番がずれていく
                try? launcher.stop()
                throw BridgeProvisionerError.notReady(port: port, underlying: error)
            }
            log("✅ \(name): ブリッジ準備完了(port \(port))")
            provisioned.append(ProvisionedIOSDevice(
                name: name, udid: sim.udid, simulatorName: sim.name, port: port))
        }
        return provisioned
    }

    /// DeviceBooter.shutdownOne が停止対象ブリッジの特定に使うため public
    public func scanRunningBridges(catalog: [SimDeviceInfo]) async -> [UInt16: String?] {
        await withTaskGroup(of: (UInt16, String?)?.self,
                            returning: [UInt16: String?].self) { group in
            for port in portRange {
                group.addTask {
                    let client = BridgeClient(port: port, timeoutSeconds: 2)
                    guard let status = try? await client.status(), status.ready else {
                        return nil
                    }
                    // デバイス名 → UDID(同名の起動中シミュレータが複数なら特定不能 = nil)
                    let booted = catalog.filter { $0.booted && $0.name == status.device }
                    return (port, booted.count == 1 ? booted[0].udid : nil)
                }
            }
            var result: [UInt16: String?] = [:]
            for await entry in group {
                if let (port, udid) = entry { result[port] = udid }
            }
            return result
        }
    }

    /// 空きポートの採番: spec.port 指定があればそれ(使用中なら次へ)、なければ範囲の先頭から
    func assignPort(preferred: UInt16?, used: inout Set<UInt16>) throws -> UInt16 {
        if let preferred, !used.contains(preferred) {
            used.insert(preferred)
            return preferred
        }
        for port in portRange where !used.contains(port)
            && !FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent(".ftester/bridge-\(port).pid").path) {
            used.insert(port)
            return port
        }
        throw BridgeProvisionerError.noFreePort(scanned: portRange)
    }
}
