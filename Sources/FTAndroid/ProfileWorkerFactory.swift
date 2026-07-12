// 解決済み実行プロファイル(ResolvedProfile)→ RunWorker 群の構築。CLI(ProfileRunner)から使う。
// FTBridgeClient と FTAndroid の両方に依存するため、このモジュール(FTAndroid)に置く。

import Foundation
import FTBridgeClient
import FTCore

public enum ProfileWorkerFactory {

    public struct InstallError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
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
                workers.append(RunWorker(
                    label: "\(device.name)(ios:\(device.port))", platform: "ios",
                    driver: BridgeClient(port: device.port),
                    connection: DriverConnection(platform: "ios", port: device.port,
                                                 engine: engine, udid: device.udid,
                                                 xcuiPort: device.xcuiPort),
                    logicalName: device.name))
            }
        }

        for device in resolved.androidDevices {
            let serial = try AndroidDeviceCatalog.resolveSerial(spec: device.spec)
            let driver = try AndroidDriver(serial: serial)
            workers.append(RunWorker(
                label: "\(device.name)(android:\(serial))", platform: "android",
                driver: driver,
                connection: DriverConnection(platform: "android", serial: serial),
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

    /// インストール失敗ワーカーは離脱し残りが続行する(全滅時のみエラー)
    public static func installIfNeeded(apps: [String: ResolvedAppTarget],
                                       workers: [RunWorker],
                                       log: @escaping (String) -> Void) async throws -> [RunWorker] {
        var pending: [(worker: RunWorker, appPath: String)] = []
        var passthrough: [RunWorker] = []
        for worker in workers {
            // inapp/hybrid の iOS はプロビジョニング時にインストール済み。ここで入れ直すと
            // 起動中の in-app ブリッジ(アプリ内常駐)が simctl install で終了してしまうため必ずスキップ
            if worker.platform == "ios", let engine = worker.connection.engine,
               engine == "inapp" || engine == "hybrid" {
                passthrough.append(worker)
                continue
            }
            if let app = apps[worker.platform], let appPath = app.appPath, app.autoInstall {
                guard FileManager.default.fileExists(atPath: appPath) else {
                    throw InstallError(message: "パッケージファイルが見つかりません: \(appPath)")
                }
                // 差分スキップ: インストール済み内容がパッケージファイルと同一なら入れ直さない
                if installedIsCurrent(worker: worker, app: app, appPath: appPath) {
                    log("→ \(worker.label): インストール済みアプリが最新のためスキップ(autoInstall)")
                    passthrough.append(worker)
                } else {
                    pending.append((worker, appPath))
                }
            } else {
                passthrough.append(worker)
            }
        }
        guard !pending.isEmpty else { return workers }

        log("→ アプリをインストール(\(pending.count) デバイス)...")
        let survivors = await withTaskGroup(of: (String, Bool).self,
                                            returning: Set<String>.self) { group in
            for (worker, appPath) in pending {
                group.addTask {
                    do {
                        try await worker.driver.install(packagePath: appPath)
                        log("✅ \(worker.label): インストール完了")
                        return (worker.label, true)
                    } catch {
                        log("❌ \(worker.label): インストール失敗のため離脱 — "
                            + error.localizedDescription)
                        return (worker.label, false)
                    }
                }
            }
            var passed = Set<String>()
            for await (label, ok) in group where ok { passed.insert(label) }
            return passed
        }

        let result = passthrough + pending.map(\.worker).filter { survivors.contains($0.label) }
        guard !result.isEmpty else {
            throw InstallError(message: "全ワーカーがインストールに失敗しました")
        }
        return result
    }
}
