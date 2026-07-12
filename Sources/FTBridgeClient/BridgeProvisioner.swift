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
    /// 主ブリッジのポート(inapp/xcuitest)。engine=hybrid のとき in-app ブリッジのポート
    public let port: UInt16
    /// 駆動エンジン("xcuitest" / "inapp" / "hybrid")。DriverConnection 経由でサブプロセスへ伝える
    public let engine: String
    /// engine=hybrid のフォールバック用 XCUITest ブリッジのポート(hybrid 以外は nil)
    public let xcuiPort: UInt16?

    public init(name: String, udid: String, simulatorName: String, port: UInt16,
                engine: String, xcuiPort: UInt16? = nil) {
        self.name = name
        self.udid = udid
        self.simulatorName = simulatorName
        self.port = port
        self.engine = engine
        self.xcuiPort = xcuiPort
    }
}

public enum BridgeProvisionerError: Error, LocalizedError {
    case noFreePort(scanned: ClosedRange<UInt16>)
    /// waitUntilReady() が失敗した場合(後始末として起動済みプロセス/pidファイルは停止済み)
    case notReady(port: UInt16, underlying: Error)
    /// engine="inapp" のブリッジを新規起動するのに bundleID が無い(フォールバックしない=単一実装)
    case inAppNeedsBundleID(name: String)

    public var errorDescription: String? {
        switch self {
        case .noFreePort(let scanned):
            return "空きポートがありません(走査範囲: \(scanned.lowerBound)〜\(scanned.upperBound))"
        case .notReady(let port, let underlying):
            return "ブリッジが時間内に準備できませんでした(port \(port)): \(underlying)"
        case .inAppNeedsBundleID(let name):
            return "\(name): engine=inapp のブリッジ起動にはアプリの bundleID が必要です。"
                + "apps プロファイルの ios.app を設定してください"
                + "(device/live 等 bundleID を渡さない経路は engine=inapp 非対応です)"
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

    /// 稼働中ブリッジ(シミュレータ UDID が一致)は再利用し、不足分は空きポートで起動する。
    /// engine="inapp" のデバイスは XCUITest ではなく dylib 注入で起動する(bundleID が必要)。
    public func provision(devices: [(name: String, spec: DeviceSpec)],
                          bundleID: String? = nil,
                          log: @escaping (String) -> Void) async throws -> [ProvisionedIOSDevice] {
        let catalog = try SimulatorCatalog.devices()

        // 1. デバイス指定 → シミュレータ実体(UDID)
        var targets: [(name: String, spec: DeviceSpec, sim: SimDeviceInfo)] = []
        for (name, spec) in devices {
            let sim = try SimulatorCatalog.resolve(spec: spec, in: catalog)
            targets.append((name, spec, sim))
        }

        // 2. 稼働中ブリッジのスキャン(ポート → (UDID, engine)。同一 UDID に inapp/xcuitest が
        // 共存する hybrid のため、engine まで見て正しいブリッジを再利用する)
        let running = await scanRunningBridges(catalog: catalog)
        if !running.isEmpty {
            let summary = running.keys.sorted().map(String.init).joined(separator: ", ")
            log("→ 稼働中ブリッジ: port \(summary)")
        }

        // 3. 照合と起動。hybrid は in-app(主)+ XCUITest(フォールバック)の2ブリッジを立てる。
        var provisioned: [ProvisionedIOSDevice] = []
        var usedPorts = Set(running.keys)
        var claimed = Set<UInt16>()  // 1回の provision 内で同じ稼働ブリッジを二重占有しないため
        for (name, spec, sim) in targets {
            let engine = spec.engine ?? "xcuitest"
            if engine == "hybrid" {
                let inappPort = try await provisionBridge(
                    engine: "inapp", preferred: spec.port, name: name, sim: sim, bundleID: bundleID,
                    running: running, claimed: &claimed, usedPorts: &usedPorts, log: log)
                let xcuiPort = try await provisionBridge(
                    engine: "xcuitest", preferred: nil, name: name, sim: sim, bundleID: bundleID,
                    running: running, claimed: &claimed, usedPorts: &usedPorts, log: log)
                provisioned.append(ProvisionedIOSDevice(
                    name: name, udid: sim.udid, simulatorName: sim.name, port: inappPort,
                    engine: "hybrid", xcuiPort: xcuiPort))
            } else {
                let port = try await provisionBridge(
                    engine: engine, preferred: spec.port, name: name, sim: sim, bundleID: bundleID,
                    running: running, claimed: &claimed, usedPorts: &usedPorts, log: log)
                provisioned.append(ProvisionedIOSDevice(
                    name: name, udid: sim.udid, simulatorName: sim.name, port: port, engine: engine))
            }
        }
        return provisioned
    }

    /// 1 デバイス・1 エンジンのブリッジを供給する。同一 UDID・同一 engine の稼働中ブリッジ(未占有)は
    /// 再利用(launch しないので bundleID 不要)、無ければ空きポートで起動する。
    private func provisionBridge(engine: String, preferred: UInt16?, name: String, sim: SimDeviceInfo,
                                 bundleID: String?, running: [UInt16: RunningBridge],
                                 claimed: inout Set<UInt16>, usedPorts: inout Set<UInt16>,
                                 log: @escaping (String) -> Void) async throws -> UInt16 {
        if let port = running.first(where: {
            $0.value.udid == sim.udid && $0.value.engine == engine && !claimed.contains($0.key)
        })?.key {
            claimed.insert(port)
            log("✅ \(name): 稼働中 \(engine) ブリッジを再利用(port \(port), \(sim.name))")
            return port
        }
        let port = try assignPort(preferred: preferred, used: &usedPorts)
        claimed.insert(port)
        log("→ \(name): \(engine) ブリッジ起動(port \(port), \(sim.name) \(sim.os))...")
        if engine == "inapp" {
            // in-app の新規起動には注入対象アプリの bundleID が要る。無ければ XCUITest に
            // フォールバックせず明示エラー(単一実装。device/live 等は engine=inapp 非対応)。
            guard let bundleID else {
                throw BridgeProvisionerError.inAppNeedsBundleID(name: name)
            }
            let launcher = InAppLauncher(repoRoot: repoRoot, udid: sim.udid, port: port)
            try launcher.buildIfNeeded()
            try await launcher.relaunch(bundleID: bundleID)
        } else {
            let launcher = BridgeLauncher(repoRoot: repoRoot, device: sim.udid, port: port)
            try await Task.detached(priority: .userInitiated) {
                try launcher.generateProjectIfNeeded()
                do {
                    try launcher.startDetached()
                } catch LauncherError.xctestrunNotFound {
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
        }
        log("✅ \(name): \(engine) ブリッジ準備完了(port \(port))")
        return port
    }

    /// 稼働中ブリッジ 1 つの識別情報(接続先 UDID・engine 種別)
    public struct RunningBridge: Sendable {
        public let udid: String?
        public let engine: String
    }

    /// DeviceBooter.shutdownOne が停止対象ブリッジの特定に使うため public。
    /// engine は /status の engine(旧ブリッジで nil なら "xcuitest" とみなす)。
    public func scanRunningBridges(catalog: [SimDeviceInfo]) async -> [UInt16: RunningBridge] {
        await withTaskGroup(of: (UInt16, RunningBridge)?.self,
                            returning: [UInt16: RunningBridge].self) { group in
            for port in portRange {
                group.addTask {
                    let client = BridgeClient(port: port, timeoutSeconds: 2)
                    guard let status = try? await client.status(), status.ready else {
                        return nil
                    }
                    // デバイス名 → UDID(同名の起動中シミュレータが複数なら特定不能 = nil)
                    let booted = catalog.filter { $0.booted && $0.name == status.device }
                    let udid = booted.count == 1 ? booted[0].udid : nil
                    return (port, RunningBridge(udid: udid, engine: status.engine ?? "xcuitest"))
                }
            }
            var result: [UInt16: RunningBridge] = [:]
            for await entry in group {
                if let (port, rb) = entry { result[port] = rb }
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
