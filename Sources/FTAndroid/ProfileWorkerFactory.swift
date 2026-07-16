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
        var workers: [RunWorker] = []

        if !resolved.iosDevices.isEmpty {
            let provisioner = BridgeProvisioner(repoRoot: repoRoot)
            let iosApp = resolved.apps["ios"]
            let provisioned = try await provisioner.provision(
                devices: resolved.iosDevices.map { ($0.name, $0.spec) },
                bundleID: iosApp?.bundleID,
                preinstallAppPath: iosApp?.autoInstall == true ? iosApp?.appPath : nil,
                log: log)
            for device in provisioned {
                // engine=inapp/hybrid のときサブプロセスは InAppDriver(+hybrid は SystemUIDriver
                // フォールバック)を使う。ホスト warmup 用 driver は in-app ブリッジへの BridgeClient
                // でよい(in-app も HTTP 応答するため)。
                let engine = (device.engine == "inapp" || device.engine == "hybrid") ? device.engine : nil
                // suspend された in-app アプリは /status が無応答になるため、注入先アプリの bundleID を
                // 明示的に渡してサブプロセスの inapp/XCUITest ルーティングを確定させる(engine 有りのみ)
                let inappBundleID = engine != nil ? iosApp?.bundleID : nil
                workers.append(RunWorker(
                    label: "\(device.name)(ios:\(device.port))", platform: "ios",
                    driver: BridgeClient(port: device.port),
                    connection: DriverConnection(platform: "ios", port: device.port,
                                                 engine: engine, udid: device.udid,
                                                 xcuiPort: device.xcuiPort,
                                                 inappBundleID: inappBundleID,
                                                 deviceName: device.name),
                    logicalName: device.name))
            }
        }

        for device in resolved.androidDevices {
            let serial = try AndroidDeviceCatalog.resolveSerial(spec: device.spec)
            let driver = try AndroidDriver(serial: serial)
            workers.append(RunWorker(
                label: "\(device.name)(android:\(serial))", platform: "android",
                driver: driver,
                connection: DriverConnection(platform: "android", serial: serial,
                                             deviceName: device.name),
                logicalName: device.name))
        }
        guard !workers.isEmpty else {
            throw InstallError(message: "実行可能なワーカーがありません(全デバイスが離脱しました)")
        }
        return workers
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
