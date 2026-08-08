// VSCode拡張のライブ操作パネル(アプリ切り替え)向け: デバイスのインストール済みアプリ一覧を
// JSON で stdout に出力する(ftester api list-apps)。stdout には結果1行の JSON だけを出す
// (診断は stderr のみ。ApiListDevicesCommand.swift と同じ流儀)。
//
// iOS のパース・UDID解決は Sources/FTBridgeClient/SimulatorAppCatalog.swift に委譲
// (MCP の ft_list_apps も同じ実装を使う。片方だけ変えない)。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct ApiListApps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-apps",
        abstract: "Print the list of apps installed on the device as JSON on stdout (diagnostics on stderr only)")

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let apps: [ApiAppEntry]
        switch driverOptions.platform {
        case "ios":
            apps = try await Self.iosApps(port: driverOptions.port)
        case "android":
            apps = try Self.androidApps(serial: driverOptions.serial)
        default:
            throw ValidationError("platform must be ios or android: \(driverOptions.platform)")
        }

        let output = ApiListAppsOutput(apps: apps, platform: driverOptions.platform)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }

    private static func iosApps(port: UInt16) async throws -> [ApiAppEntry] {
        let status = try await BridgeClient(port: port, timeoutSeconds: 10).status()
        let udid: String
        let apps: [SimulatorAppCatalog.App]
        do {
            udid = try SimulatorAppCatalog.bootedSimulatorUDID(named: status.device)
            apps = try SimulatorAppCatalog.apps(udid: udid)
        } catch let error as LocalizedError {
            throw ValidationError(error.errorDescription ?? "\(error)")
        }
        return apps.map { ApiAppEntry(id: $0.id, name: $0.name, type: $0.isUser ? "user" : "system") }
    }

    private static func androidApps(serial: String?) throws -> [ApiAppEntry] {
        let driver = try AndroidDriver(serial: serial)
        let packages = try driver.listInstalledPackages()
        return packages
            .map { ApiAppEntry(id: $0, name: $0, type: "user") }
            .sorted { $0.name < $1.name }
    }
}

/// ftester api list-apps の 1 アプリ分。省略可能フィールドは無いため synthesized encode でよい
private struct ApiAppEntry: Encodable {
    let id: String
    let name: String
    let type: String
}

/// ftester api list-apps の出力全体
private struct ApiListAppsOutput: Encodable {
    let apps: [ApiAppEntry]
    let platform: String
}
