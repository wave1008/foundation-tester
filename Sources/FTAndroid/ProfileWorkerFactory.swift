// 解決済み実行プロファイル(ResolvedProfile)→ RunWorker 群の構築。CLI(ProfileRunner)から使う。
// FTBridgeClient と FTAndroid の両方に依存するため、このモジュール(FTAndroid)に置く。

import Foundation
import FTBridgeClient
import FTCore

public enum ProfileWorkerFactory {

    public struct InstallError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    public static func buildWorkers(resolved: ResolvedProfile, repoRoot: URL,
                                    log: @escaping (String) -> Void) async throws -> [RunWorker] {
        let workers = try await buildIOSWorkers(resolved: resolved, repoRoot: repoRoot, log: log)
            + (try buildAndroidWorkers(resolved: resolved))
        guard !workers.isEmpty else {
            throw InstallError(message: "実行可能なワーカーがありません(全デバイスが離脱しました)")
        }
        return workers
    }

    /// iOS ワーカーのみ構築(ブリッジ供給込み=数十秒かかりうる)。Android と分離して呼べるのは
    /// 「Android を iOS 供給の完了待ちにしない」ため(RunOrchestrator の lateWorkers 参照)。
    public static func buildIOSWorkers(resolved: ResolvedProfile, repoRoot: URL,
                                       log: @escaping (String) -> Void) async throws -> [RunWorker] {
        guard !resolved.iosDevices.isEmpty else { return [] }
        let provisioner = BridgeProvisioner(repoRoot: repoRoot)
        let iosApp = resolved.apps["ios"]
        let provisioned = try await provisioner.provision(
            devices: resolved.iosDevices.map { ($0.name, $0.spec) },
            bundleID: iosApp?.bundleID,
            preinstallAppPath: iosApp?.autoInstall == true ? iosApp?.appPath : nil,
            log: log)
        return provisioned.map { makeIOSWorker(device: $0, iosApp: iosApp) }
    }

    /// Android ワーカーのみ構築(serial 照合+ドライバ生成のみ=数秒)。
    public static func buildAndroidWorkers(resolved: ResolvedProfile) throws -> [RunWorker] {
        try resolved.androidDevices.map { device in
            let serial = try AndroidDeviceCatalog.resolveSerial(spec: device.spec)
            let driver = try AndroidDriver(serial: serial)
            return RunWorker(
                label: "\(device.name)(android:\(serial))", platform: "android",
                driver: driver,
                connection: DriverConnection(platform: "android", serial: serial,
                                             deviceName: device.name),
                logicalName: device.name)
        }
    }

    /// engine=inapp/hybrid のときサブプロセスは InAppDriver(+hybrid は SystemUIDriver フォールバック)を
    /// 使う。ホスト warmup 用 driver は in-app ブリッジへの BridgeClient でよい(in-app も HTTP 応答する)。
    /// suspend された in-app アプリは /status が無応答になるため、注入先アプリの bundleID を明示的に渡して
    /// サブプロセスの inapp/XCUITest ルーティングを確定させる(engine 有りのみ)
    private static func makeIOSWorker(device: ProvisionedIOSDevice, iosApp: ResolvedAppTarget?) -> RunWorker {
        let engine = (device.engine == "inapp" || device.engine == "hybrid") ? device.engine : nil
        let inappBundleID = engine != nil ? iosApp?.bundleID : nil
        return RunWorker(
            label: "\(device.name)(ios:\(device.port))", platform: "ios",
            driver: BridgeClient(port: device.port),
            connection: DriverConnection(platform: "ios", port: device.port,
                                         engine: engine, udid: device.udid,
                                         xcuiPort: device.xcuiPort,
                                         inappBundleID: inappBundleID,
                                         deviceName: device.name),
            logicalName: device.name)
    }

    /// logicalName の1台だけを再供給する。到達不能・供給失敗は nil(throw しない)。
    public static func buildWorker(forLogicalName name: String, resolved: ResolvedProfile,
                                   repoRoot: URL, log: @escaping (String) -> Void) async -> RunWorker? {
        if let device = resolved.iosDevices.first(where: { $0.name == name }) {
            let provisioner = BridgeProvisioner(repoRoot: repoRoot)
            let iosApp = resolved.apps["ios"]
            // provision に 60s の期限を切る: ウェッジしたブリッジは接続を受けたまま応答せず、
            // BridgeClient の既定 120s/リクエストに任せると復帰ポーリング1回が数分止まる
            // (呼び出し側 reviveWorker の Date 期限は await 中は効かない)。キャンセルで確実に抜ける。
            let provisioned = await withTaskGroup(of: [ProvisionedIOSDevice]?.self) { group in
                group.addTask {
                    try? await provisioner.provision(
                        devices: [(device.name, device.spec)],
                        bundleID: iosApp?.bundleID,
                        preinstallAppPath: iosApp?.autoInstall == true ? iosApp?.appPath : nil,
                        log: log)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let first = provisioned?.first else { return nil }
            return makeIOSWorker(device: first, iosApp: iosApp)
        }
        if let device = resolved.androidDevices.first(where: { $0.name == name }) {
            do {
                let serial = try AndroidDeviceCatalog.resolveSerial(spec: device.spec)
                let driver = try AndroidDriver(serial: serial)
                // ゲスト OS 再起動中でも serial 解決・ドライバ構築は成功してしまうため、status の
                // 疎通を確認してから返す(無検証で返すと呼び出し側が「復帰成功→即 status 死亡」で
                // 復帰上限を空費し、REVIVE_TIMEOUT の再試行ループが機能しない)。ウェッジした
                // ブリッジは応答を返さないことがあるため 10s 期限で打ち切る(iOS 分岐の 60s と同型)
                let reachable = await withTaskGroup(of: Bool.self) { group in
                    group.addTask { (try? await driver.status()) != nil }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        return false
                    }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                guard reachable else { return nil }
                return RunWorker(
                    label: "\(device.name)(android:\(serial))", platform: "android",
                    driver: driver,
                    connection: DriverConnection(platform: "android", serial: serial,
                                                 deviceName: device.name),
                    logicalName: device.name)
            } catch {
                return nil
            }
        }
        return nil
    }

    /// autoInstall の差分スキップ判定(iOS: バンドル深比較 / Android: APK md5)。
    /// 判定不能は false(=インストールする)の安全側。
    private static func installedIsCurrent(worker: RunWorker, app: ResolvedAppTarget,
                                           appPath: String) -> Bool {
        if worker.platform == "ios" {
            guard let udid = worker.connection.udid else { return false }
            return InstalledAppCheck.simulatorAppIsCurrent(
                udid: udid, bundleID: app.bundleID, appPath: appPath)
        }
        guard let android = worker.driver as? AndroidDriver else { return false }
        return android.installedPackageIsCurrent(packageID: app.bundleID, apkPath: appPath)
    }

    /// インストール失敗ワーカーは離脱し残りが続行する(全滅時のみエラー)。
    /// 判定(installedIsCurrent)〜必要なら install まではワーカー単位で並列(1タスク内で判定→install を直列に実行)。
    /// 戻り値は workers 順を維持する。
    /// forceAndroidInstall: true のとき android は autoInstall=false でも appPath があれば
    /// インストール候補に含める(AndroidDataWiper の Wipe Data でアプリが消えているため)
    public static func installIfNeeded(apps: [String: ResolvedAppTarget],
                                       workers: [RunWorker],
                                       forceAndroidInstall: Bool = false,
                                       log: @escaping (String) -> Void) async throws -> [RunWorker] {
        // 呼び出し元の log はスレッド安全という契約が無い(CLI 側 print 等)ため、並列区間からは
        // このロック越しラッパーのみを使う。
        let lock = NSLock()
        let safeLog: (String) -> Void = { msg in
            lock.lock()
            defer { lock.unlock() }
            log(msg)
        }

        var candidates: [(index: Int, worker: RunWorker, app: ResolvedAppTarget, appPath: String)] = []
        var passthrough: [(index: Int, worker: RunWorker)] = []
        for (index, worker) in workers.enumerated() {
            // inapp/hybrid の iOS はプロビジョニング時にインストール済み。ここで入れ直すと
            // 起動中の in-app ブリッジ(アプリ内常駐)が simctl install で終了してしまうため必ずスキップ
            if worker.platform == "ios", let engine = worker.connection.engine,
               engine == "inapp" || engine == "hybrid" {
                passthrough.append((index, worker))
                continue
            }
            let forceThis = forceAndroidInstall && worker.platform == "android"
            if let app = apps[worker.platform], let appPath = app.appPath,
               app.autoInstall || forceThis {
                // 存在確認だけは直列のまま行う: 確定的な順序で早期 throw するため
                // (差分判定・インストールは下の TaskGroup で並列化)
                guard FileManager.default.fileExists(atPath: appPath) else {
                    throw InstallError(message: "パッケージファイルが見つかりません: \(appPath)")
                }
                candidates.append((index, worker, app, appPath))
            } else {
                if forceThis, apps[worker.platform]?.appPath == nil {
                    safeLog("⚠️ \(worker.label): Wipe Data 後の再インストールに appPath が必要です"
                        + "(apps/ の appPath 未指定)")
                }
                passthrough.append((index, worker))
            }
        }
        guard !candidates.isEmpty else { return workers }

        // N は差分判定前の候補数(判定した結果スキップになるものも含む数)
        log("→ アプリを確認・インストール(\(candidates.count) デバイス)...")

        let installed = await withTaskGroup(of: (Int, RunWorker?).self,
                                            returning: [(Int, RunWorker)].self) { group in
            for (index, worker, app, appPath) in candidates {
                group.addTask {
                    // 差分スキップ: インストール済み内容がパッケージファイルと同一なら入れ直さない
                    if installedIsCurrent(worker: worker, app: app, appPath: appPath) {
                        safeLog("→ \(worker.label): インストール済みアプリが最新のためスキップ(autoInstall)")
                        return (index, worker)
                    }
                    do {
                        try await worker.driver.install(packagePath: appPath)
                        safeLog("✅ \(worker.label): インストール完了")
                        return (index, worker)
                    } catch {
                        safeLog("❌ \(worker.label): インストール失敗のため離脱 — "
                            + error.localizedDescription)
                        return (index, nil)
                    }
                }
            }
            var results: [(Int, RunWorker)] = []
            for await (index, worker) in group {
                if let worker { results.append((index, worker)) }
            }
            return results
        }

        // TaskGroup は完了順で返るため、passthrough と合流して index で元の workers 順に戻す
        let result = (passthrough + installed.map { (index: $0.0, worker: $0.1) })
            .sorted { $0.index < $1.index }.map { $0.worker }
        guard !result.isEmpty else {
            throw InstallError(message: "全ワーカーがインストールに失敗しました")
        }
        return result
    }
}
