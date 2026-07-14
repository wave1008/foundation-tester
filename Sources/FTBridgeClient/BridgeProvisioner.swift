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
    /// engine=inapp でアプリ未インストール・preinstallAppPath も無い(provision() が該当デバイスのみ離脱)
    case appNotInstalled(device: String, bundleID: String, udid: String)
    /// preinstallAppPath 指定時の simctl install 自体が失敗した
    case preinstallFailed(device: String, detail: String)

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
        case .appNotInstalled(_, let bundleID, let udid):
            // device 名は provision() の離脱ログが行頭に付けるためここには含めない
            return "\(bundleID) が未インストールのため離脱します(engine=inapp は事前インストール必須)。"
                + "`xcrun simctl install \(udid) <app>` で導入するか、"
                + "apps プロファイルに appPath+autoInstall を設定してください"
        case .preinstallFailed(let device, let detail):
            return "\(device): アプリの自動インストールに失敗しました:\n\(detail)"
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

    /// 1 デバイス・1 エンジン分の供給プラン。planBridge(副作用なし・await なし)が確定し、
    /// 実処理(停止・起動)は並列実行フェーズが担う。ポート採番はプランニングで確定済み。
    enum EnginePlan {
        case reuse(port: UInt16)
        /// stopStalePort: 起動前に停止すべき旧版 xcuitest ブリッジのポート。
        /// needsInstall: inapp の autoInstall 差し替え(インストールファイルが更新済み)
        case launch(port: UInt16, needsInstall: Bool, stopStalePort: UInt16?)

        var port: UInt16 {
            switch self {
            case .reuse(let port): return port
            case .launch(let port, _, _): return port
            }
        }
        var isLaunch: Bool {
            if case .launch = self { return true }
            return false
        }
    }

    /// 1 デバイス分のプラン。bridges は実行順(hybrid: inapp → xcuitest の 2 要素、他は 1 要素)
    struct DevicePlan {
        /// 元のデバイス順(結果配列の並びの復元と「最初のエラー」の決定に使う)
        let index: Int
        let name: String
        let sim: SimDeviceInfo
        /// ProvisionedIOSDevice.engine に入る値("hybrid" 含む)
        let engine: String
        let bridges: [(engine: String, plan: EnginePlan)]
    }

    /// 稼働中ブリッジ(シミュレータ UDID が一致)は再利用し、不足分は空きポートで起動する。
    /// engine="inapp" のデバイスは XCUITest ではなく dylib 注入で起動する(bundleID が必要)。
    /// preinstallAppPath: apps プロファイルの appPath+autoInstall が有効なときのアプリパス。
    /// inapp 起動時に未インストールを検出したらその場で simctl install する
    /// (ProfileWorkerFactory.installIfNeeded は provision の後段のため、それより前にここで埋める)。
    /// 流れ: 差分判定(並列)→ プランニング(直列)→ 共有ビルド(直列)→ 起動(デバイス単位で並列)。
    public func provision(devices: [(name: String, spec: DeviceSpec)],
                          bundleID: String? = nil,
                          preinstallAppPath: String? = nil,
                          log: @escaping (String) -> Void) async throws -> [ProvisionedIOSDevice] {
        // 呼び出し側の log(logStderr / print 等)はスレッド安全の契約が無い。
        // 並列フェーズからは必ずこのロック付きラッパーを使う
        let logLock = NSLock()
        let safeLog: (String) -> Void = { message in
            logLock.lock()
            defer { logLock.unlock() }
            log(message)
        }

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
            safeLog("→ 稼働中ブリッジ: port \(summary)")
        }

        // 3. inapp/hybrid の autoInstall 差分判定(バンドル深比較で遅い)を並列に事前評価
        // (プランニングが needsInstall の決定に使うため先に必要)
        let appIsCurrent = await checkInstalledAppCurrency(
            targets: targets, bundleID: bundleID, preinstallAppPath: preinstallAppPath)

        // 4. プランニング(直列・await なし)。ポート採番の一意性(usedPorts/claimed)のため
        // 全デバイスを必ず直列で処理する
        var usedPorts = Set(running.keys)
        var claimed = Set<UInt16>()  // 1回の provision 内で同じ稼働ブリッジを二重占有しないため
        var plans: [DevicePlan] = []
        for (index, target) in targets.enumerated() {
            let engine = target.spec.engine ?? "xcuitest"
            var bridges: [(engine: String, plan: EnginePlan)] = []
            if engine == "hybrid" {
                // in-app(主)+ XCUITest(フォールバック)の2ブリッジ
                bridges.append(("inapp", try planBridge(
                    engine: "inapp", preferred: target.spec.port, name: target.name,
                    sim: target.sim, bundleID: bundleID, appIsCurrent: appIsCurrent,
                    preinstallAppPath: preinstallAppPath,
                    running: running, claimed: &claimed, usedPorts: &usedPorts)))
                bridges.append(("xcuitest", try planBridge(
                    engine: "xcuitest", preferred: nil, name: target.name,
                    sim: target.sim, bundleID: bundleID, appIsCurrent: appIsCurrent,
                    preinstallAppPath: preinstallAppPath,
                    running: running, claimed: &claimed, usedPorts: &usedPorts)))
            } else {
                bridges.append((engine, try planBridge(
                    engine: engine, preferred: target.spec.port, name: target.name,
                    sim: target.sim, bundleID: bundleID, appIsCurrent: appIsCurrent,
                    preinstallAppPath: preinstallAppPath,
                    running: running, claimed: &claimed, usedPorts: &usedPorts)))
            }
            plans.append(DevicePlan(index: index, name: target.name, sim: target.sim,
                                    engine: engine, bridges: bridges))
        }

        // 5. 共有ビルド(直列)。並列起動フェーズより前に必ず済ませる
        try await prepareSharedBuilds(plans: plans, log: safeLog)

        // 6. 起動(デバイス単位で並列)
        let outcomes = await withTaskGroup(
            of: (Int, Result<ProvisionedIOSDevice, Error>).self,
            returning: [Int: Result<ProvisionedIOSDevice, Error>].self) { group in
            for plan in plans {
                group.addTask {
                    do {
                        let device = try await self.executeDevice(
                            plan: plan, bundleID: bundleID,
                            preinstallAppPath: preinstallAppPath, log: safeLog)
                        return (plan.index, .success(device))
                    } catch {
                        return (plan.index, .failure(error))
                    }
                }
            }
            var results: [Int: Result<ProvisionedIOSDevice, Error>] = [:]
            for await (index, result) in group { results[index] = result }
            return results
        }

        // 7. 元のデバイス順に集約。appNotInstalled はそのデバイスだけ離脱して続行。
        // それ以外のエラーは全タスク完走後にデバイス順で最初の1つを throw(直列版は途中 throw で
        // 後続が未着手だったが、並列版は起動済みブリッジが常駐資産として残るだけなので完走待ちでよい)
        var provisioned: [ProvisionedIOSDevice] = []
        var firstError: Error?
        for plan in plans {
            guard let outcome = outcomes[plan.index] else { continue }
            switch outcome {
            case .success(let device):
                provisioned.append(device)
            case .failure(let error):
                if case BridgeProvisionerError.appNotInstalled = error {
                    // installIfNeeded の「失敗ワーカーは離脱し残りが続行」と同じ思想
                    safeLog("❌ \(plan.name): \(error.localizedDescription)")
                } else if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError { throw firstError }
        return provisioned
    }

    /// autoInstall 付き inapp/hybrid の「インストール済みアプリが最新か」を並列評価(UDID → 最新か)。
    /// InstalledAppCheck はバンドル全バイト深比較でアプリサイズ比例に遅い(installIfNeeded の
    /// 差分スキップと共用)。判定不能・マップ欠落は false 扱い=インストールする安全側
    private func checkInstalledAppCurrency(
        targets: [(name: String, spec: DeviceSpec, sim: SimDeviceInfo)],
        bundleID: String?, preinstallAppPath: String?) async -> [String: Bool] {
        guard let bundleID, let preinstallAppPath else { return [:] }
        let udids = Set(targets.filter {
            let engine = $0.spec.engine ?? "xcuitest"
            return engine == "inapp" || engine == "hybrid"
        }.map { $0.sim.udid })
        guard !udids.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, Bool).self,
                                   returning: [String: Bool].self) { group in
            for udid in udids {
                group.addTask {
                    (udid, InstalledAppCheck.simulatorAppIsCurrent(
                        udid: udid, bundleID: bundleID, appPath: preinstallAppPath))
                }
            }
            var result: [String: Bool] = [:]
            for await (udid, current) in group { result[udid] = current }
            return result
        }
    }

    /// 1 デバイス・1 エンジンのプラン決定。副作用は claimed/usedPorts の更新のみ
    /// (ログ・プロセス操作・await なし=単体テスト可能に保つこと)
    private func planBridge(engine: String, preferred: UInt16?, name: String, sim: SimDeviceInfo,
                            bundleID: String?, appIsCurrent: [String: Bool],
                            preinstallAppPath: String?,
                            running: [UInt16: RunningBridge],
                            claimed: inout Set<UInt16>,
                            usedPorts: inout Set<UInt16>) throws -> EnginePlan {
        // autoInstall(preinstallAppPath)付き inapp は「インストールファイルが更新されているとき
        // だけ」install+注入起動で差し替える(install は起動中アプリ=in-app ブリッジを終了させる
        // ため、後段の installIfNeeded で入れ直す順序は不可=あちらは inapp/hybrid をスキップする)。
        // 最新なら稼働中ブリッジを再利用して install も relaunch も省く。
        var inappNeedsInstall = false
        if engine == "inapp", preinstallAppPath != nil, bundleID != nil {
            inappNeedsInstall = !(appIsCurrent[sim.udid] ?? false)
        }
        // xcuitest は protocolVersion が現行値と一致するときだけ再利用する(旧ビルドは 404 等の
        // 不整合を招くため。inapp は毎プロビジョンで再ビルド・再注入なので判定しない)
        if !(engine == "inapp" && inappNeedsInstall),
           let port = running.first(where: {
            $0.value.udid == sim.udid && $0.value.engine == engine && !claimed.contains($0.key)
                && (engine != "xcuitest" || $0.value.protocolVersion == BridgeAPI.bridgeProtocolVersion)
           })?.key {
            claimed.insert(port)
            return .reuse(port: port)
        }
        // 再利用できない同一 UDID・xcuitest の旧版ブリッジは止めてから新規起動する
        // (放置するとポートを握ったまま残り、次回以降の /status も旧版のまま応答し続ける)。
        // 停止(stopAndWait)は並列実行フェーズが行い、ここは採番状態の更新だけ
        var stopStalePort: UInt16?
        if engine == "xcuitest", let stale = running.first(where: {
            $0.value.udid == sim.udid && $0.value.engine == "xcuitest" && !claimed.contains($0.key)
                && $0.value.protocolVersion != BridgeAPI.bridgeProtocolVersion
        }) {
            claimed.insert(stale.key)
            usedPorts.remove(stale.key)
            stopStalePort = stale.key
        }
        let port = try assignPort(preferred: preferred, used: &usedPorts,
                                  ignoringPidFileFor: stopStalePort)
        claimed.insert(port)
        // in-app の新規起動には注入対象アプリの bundleID が要る。無ければ XCUITest に
        // フォールバックせず明示エラー(単一実装。device/live 等は engine=inapp 非対応)
        if engine == "inapp", bundleID == nil {
            throw BridgeProvisionerError.inAppNeedsBundleID(name: name)
        }
        return .launch(port: port, needsInstall: inappNeedsInstall, stopStalePort: stopStalePort)
    }

    /// 全デバイス共有のビルド成果物(in-app dylib / xcuitest の xctestrun)は、並列起動フェーズの
    /// 前にここで必ず直列に済ませる(並列に buildIfNeeded / buildForTesting が走ると出力が競合する)。
    /// xctestrun 不在時の build-for-testing もここへ前倒し(起動フェーズの startDetached では作らない)
    private func prepareSharedBuilds(plans: [DevicePlan],
                                     log: @escaping (String) -> Void) async throws {
        let launches = plans.flatMap { plan in
            plan.bridges.filter { $0.plan.isLaunch }
                .map { (sim: plan.sim, engine: $0.engine, port: $0.plan.port) }
        }
        let inapp = launches.first { $0.engine == "inapp" }
        let xcui = launches.first { $0.engine != "inapp" }
        guard inapp != nil || xcui != nil else { return }
        try await Task.detached(priority: .userInitiated) {
            if let inapp {
                // dylib は全デバイス共有(udid/port は buildIfNeeded では未使用)
                try InAppLauncher(repoRoot: repoRoot, udid: inapp.sim.udid,
                                  port: inapp.port).buildIfNeeded()
            }
            if let xcui {
                // xctestrun は全ポート共有(startDetached がポート注入コピーを作る)
                let launcher = BridgeLauncher(repoRoot: repoRoot, device: xcui.sim.udid,
                                              port: xcui.port)
                try launcher.generateProjectIfNeeded()
                if try launcher.findXCTestRun() == nil {
                    log("→ build-for-testing(初回は数分かかります)...")
                    try launcher.buildForTesting()
                }
            }
        }.value
    }

    /// 1 デバイス分のプラン実行。デバイス間は並列だが、同一デバイス内のブリッジ
    /// (hybrid の inapp → xcuitest)は同一シミュレータへの simctl 競合を避けるため直列。
    /// inapp が失敗したら xcuitest は実行しない(直列版と同じ)
    private func executeDevice(plan: DevicePlan, bundleID: String?, preinstallAppPath: String?,
                               log: @escaping (String) -> Void) async throws -> ProvisionedIOSDevice {
        var ports: [UInt16] = []
        for bridge in plan.bridges {
            ports.append(try await executeBridge(
                engine: bridge.engine, plan: bridge.plan, name: plan.name, sim: plan.sim,
                bundleID: bundleID, preinstallAppPath: preinstallAppPath, log: log))
        }
        return ProvisionedIOSDevice(
            name: plan.name, udid: plan.sim.udid, simulatorName: plan.sim.name,
            port: ports[0], engine: plan.engine,
            xcuiPort: ports.count > 1 ? ports[1] : nil)
    }

    /// 1 ブリッジ分のプラン実行(ポート採番・再利用判定はプランニングで確定済み)
    private func executeBridge(engine: String, plan: EnginePlan, name: String, sim: SimDeviceInfo,
                               bundleID: String?, preinstallAppPath: String?,
                               log: @escaping (String) -> Void) async throws -> UInt16 {
        switch plan {
        case .reuse(let port):
            log("✅ \(name): 稼働中 \(engine) ブリッジを再利用(port \(port), \(sim.name))")
            return port
        case .launch(let port, let needsInstall, let stopStalePort):
            if let stopStalePort {
                log("→ \(name): 旧ビルドのブリッジ(port \(stopStalePort))を停止して起動し直します")
                do {
                    try await BridgeLauncher(repoRoot: repoRoot, device: sim.udid,
                                             port: stopStalePort).stopAndWait()
                } catch {
                    log("⚠️ \(name): 旧ブリッジの停止に失敗しました(port \(stopStalePort)): \(error.localizedDescription)")
                }
            }
            log("→ \(name): \(engine) ブリッジ起動(port \(port), \(sim.name) \(sim.os))...")
            if engine == "inapp" {
                // planBridge が bundleID 必須を検証済み(ここは保険)
                guard let bundleID else {
                    throw BridgeProvisionerError.inAppNeedsBundleID(name: name)
                }
                let launcher = InAppLauncher(repoRoot: repoRoot, udid: sim.udid, port: port)
                // dylib ビルドは prepareSharedBuilds で完了済み(ここで buildIfNeeded すると並列で競合)
                try await Task.detached(priority: .userInitiated) {
                    try launcher.ensureBooted()  // simctl launch はブート済み前提(install も同様)
                    try self.ensureAppInstalled(deviceName: name, sim: sim, bundleID: bundleID,
                                                preinstallAppPath: preinstallAppPath,
                                                needsInstall: needsInstall, log: log)
                }.value
                try await launcher.relaunch(bundleID: bundleID)
            } else {
                let launcher = BridgeLauncher(repoRoot: repoRoot, device: sim.udid, port: port)
                // xctestrun の存在は prepareSharedBuilds が保証済み(不在なら xctestrunNotFound が
                // そのまま届く。ここで buildForTesting はしない=並列で二重ビルドさせない)
                try await Task.detached(priority: .userInitiated) {
                    try launcher.generateProjectIfNeeded()
                    try launcher.startDetached()
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
    }

    /// inapp の注入起動(simctl launch)はアプリのインストールが前提。autoInstall
    /// (preinstallAppPath)有りなら needsInstall(=installedAppIsCurrent の否定)のときだけ
    /// インストールする。無しなら存在確認のみ行い、未インストールは appNotInstalled を投げる
    /// (provision() が該当デバイスだけ離脱させて続行する)。
    private func ensureAppInstalled(deviceName: String, sim: SimDeviceInfo, bundleID: String,
                                    preinstallAppPath: String?, needsInstall: Bool,
                                    log: @escaping (String) -> Void) throws {
        if let preinstallAppPath {
            guard needsInstall else { return }
            log("→ \(deviceName): \(bundleID) をインストールします(autoInstall: 内容が更新されています)...")
            let install = try Shell.run(["xcrun", "simctl", "install", sim.udid, preinstallAppPath])
            guard install.status == 0 else {
                throw BridgeProvisionerError.preinstallFailed(device: deviceName, detail: install.tail)
            }
            log("✅ \(deviceName): インストール完了")
            return
        }
        let check = try Shell.run(["xcrun", "simctl", "get_app_container", sim.udid, bundleID])
        guard check.status == 0 else {
            throw BridgeProvisionerError.appNotInstalled(
                device: deviceName, bundleID: bundleID, udid: sim.udid)
        }
    }

    /// 稼働中ブリッジ 1 つの識別情報(接続先 UDID・engine 種別)
    struct RunningBridge: Sendable {
        let udid: String?
        let engine: String
        /// BridgeAPI.bridgeProtocolVersion。旧ブリッジは nil(xcuitest の再利用判定に使う)。
        let protocolVersion: Int?
    }

    /// provision の再利用判定用。engine・protocolVersion は /status のもの(旧ブリッジはどちらも
    /// nil。旧ブリッジは engine を "xcuitest" 扱いにするが protocolVersion は nil のままにして
    /// 再利用不可と判定させる)。
    /// 注意: /status 無応答のゾンビは映らない。停止用途には BridgeLauncher.stopMatching を使う
    /// (HTTP でなく pid ファイル+プロセス引数の UDID 照合)。
    func scanRunningBridges(catalog: [SimDeviceInfo]) async -> [UInt16: RunningBridge] {
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
                    return (port, RunningBridge(udid: udid, engine: status.engine ?? "xcuitest",
                                                protocolVersion: status.protocolVersion))
                }
            }
            var result: [UInt16: RunningBridge] = [:]
            for await entry in group {
                if let (port, rb) = entry { result[port] = rb }
            }
            return result
        }
    }

    /// 空きポートの採番: spec.port 指定があればそれ(使用中なら次へ)、なければ範囲の先頭から。
    /// ignoringPidFileFor: このポートだけ pid ファイルが残っていても空き扱いにする
    /// (停止予定の旧版 xcuitest ブリッジの「同ポート再起動」用。停止はプランニング後の
    /// 並列実行フェーズで行われるため、プランニング時点では pid ファイルがまだ残っている)
    func assignPort(preferred: UInt16?, used: inout Set<UInt16>,
                    ignoringPidFileFor: UInt16? = nil) throws -> UInt16 {
        if let preferred, !used.contains(preferred) {
            used.insert(preferred)
            return preferred
        }
        for port in portRange where !used.contains(port)
            && (port == ignoringPidFileFor
                || !FileManager.default.fileExists(
                    atPath: repoRoot.appendingPathComponent(".ftester/bridge-\(port).pid").path)) {
            used.insert(port)
            return port
        }
        throw BridgeProvisionerError.noFreePort(scanned: portRange)
    }
}
