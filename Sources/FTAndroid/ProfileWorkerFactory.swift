// ProfileWorkerFactory.swift
// 解決済み実行プロファイル(ResolvedProfile)→ RunWorker 群の構築。
// iOS はブリッジ供給(BridgeProvisioner)、Android は serial/avd 照合(AndroidDeviceCatalog)。
// CLI(ProfileRunner)と GUI(AppModel)が共用する。
// ※ FTBridgeClient と FTAndroid の両方に依存するため、このモジュールに置く。

import Foundation
import FTBridgeClient
import FTCore

public enum ProfileWorkerFactory {

    public struct InstallError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// ResolvedProfile のデバイス群からワーカーを構築する(ラベル = デバイスの論理名)
    public static func buildWorkers(resolved: ResolvedProfile, repoRoot: URL,
                                    log: @escaping (String) -> Void) async throws -> [RunWorker] {
        var workers: [RunWorker] = []

        if !resolved.iosDevices.isEmpty {
            let provisioner = BridgeProvisioner(repoRoot: repoRoot)
            let provisioned = try await provisioner.provision(
                devices: resolved.iosDevices.map { ($0.name, $0.spec) }, log: log)
            for device in provisioned {
                workers.append(RunWorker(
                    label: "\(device.name)(ios:\(device.port))", platform: "ios",
                    driver: BridgeClient(port: device.port),
                    connection: DriverConnection(platform: "ios", port: device.port)))
            }
        }

        for device in resolved.androidDevices {
            let serial = try AndroidDeviceCatalog.resolveSerial(spec: device.spec)
            let driver = try AndroidDriver(serial: serial)
            workers.append(RunWorker(
                label: "\(device.name)(android:\(serial))", platform: "android",
                driver: driver,
                connection: DriverConnection(platform: "android", serial: serial)))
        }
        return workers
    }

    /// appPath 指定+autoInstall のプラットフォームのワーカーへ並行インストールする。
    /// 失敗したワーカーは離脱(残ワーカーがキューを引き継ぐ)。全滅ならエラー
    public static func installIfNeeded(apps: [String: ResolvedAppTarget],
                                       workers: [RunWorker],
                                       log: @escaping (String) -> Void) async throws -> [RunWorker] {
        var pending: [(worker: RunWorker, appPath: String)] = []
        var passthrough: [RunWorker] = []
        for worker in workers {
            if let app = apps[worker.platform], let appPath = app.appPath, app.autoInstall {
                guard FileManager.default.fileExists(atPath: appPath) else {
                    throw InstallError(message: "パッケージファイルが見つかりません: \(appPath)")
                }
                pending.append((worker, appPath))
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
