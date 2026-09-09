// VSCode拡張のライブ操作パネル(アプリ切り替え)向け: デバイスのインストール済みアプリ一覧を
// JSON で stdout に出力する(fleetest api list-apps)。stdout には結果1行の JSON だけを出す
// (診断は stderr のみ。ApiListDevicesCommand.swift と同じ流儀)。
//
// iOS のパース・列挙は Sources/FTBridgeClient/SimulatorAppCatalog.swift(シミュレータ)/
// IOSPhysicalAppCatalog.swift(実機)に委譲する。MCP の ft_list_apps(Sources/fleetest-mcp/
// MCPServer+Dispatch.swift)もこの2つを共有するが、**宛先の仕分け(実機かどうかの判定・
// 候補 udid の集め方)は各自持つ** —— CLI は port → `.fleetest/bridge-<port>.device` の記録
// だけを見る(引数に udid が無いため)。MCP は引数の `udid:`・セッション記憶も候補にする。

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

    func validate() throws { try driverOptions.rejectVersionSkewFlag(in: "api list-apps") }

    func run() async throws {
        let apps: [ApiAppEntry]
        switch driverOptions.resolvedPlatform {
        case "ios":
            apps = try await Self.iosApps(port: driverOptions.resolvedPort)
        case "android":
            apps = try Self.androidApps(serial: driverOptions.serial)
        default:
            throw ValidationError("platform must be ios or android: \(driverOptions.resolvedPlatform)")
        }

        let output = ApiListAppsOutput(apps: apps, platform: driverOptions.resolvedPlatform)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        ConsoleOut.out(String(data: data, encoding: .utf8)!)
    }

    /// **実機判定はシミュレータへの素通し(bootedSimulatorUDID)より必ず前に置く**: 実機の
    /// `/status` は device に機種名("iPhone")しか返さず、そのまま simctl 側へ渡すと必ず throw
    /// する(欠陥はここでは起きない ―― MCP の ft_list_apps と同じ理由。MCPServer+Dispatch.swift
    /// 参照)。CLI には引数 `udid:` もセッション記憶も無いので、候補は
    /// `.fleetest/bridge-<port>.device` の記録だけ(実機の establish 経由でしか書かれない
    /// ―― IOSDeviceTransport.establish のコメント参照。仮想デバイスでは記録自体が存在しない)
    private static func iosApps(port: UInt16) async throws -> [ApiAppEntry] {
        let recordedUDID = (try? RepoRoot.find())
            .flatMap { BridgeDeviceRecord.load(port: port, repoRoot: $0) }
        do {
            switch route(recordedUDID: recordedUDID) {
            case .physical(let udid):
                return try IOSPhysicalAppCatalog.apps(udid: udid).map {
                    ApiAppEntry(id: $0.id, name: $0.name, type: $0.isUser ? "user" : "system")
                }
            case .simulator:
                // 実機は宛先も token も記録から丸ごと引く(BridgeEndpoint.resolved の doc)
                let status = try await BridgeClient(endpoint: BridgeEndpoint.resolved(port: port),
                                                    timeoutSeconds: 10).status()
                let udid = try SimulatorAppCatalog.bootedSimulatorUDID(named: status.device)
                return try SimulatorAppCatalog.apps(udid: udid).map {
                    ApiAppEntry(id: $0.id, name: $0.name, type: $0.isUser ? "user" : "system")
                }
            }
        } catch let error as LocalizedError {
            throw ValidationError(error.errorDescription ?? "\(error)")
        }
    }

    /// port → 記録 → 実機か simctl かの判定だけを切り出した純粋関数(テスト可能)
    enum IOSAppsRoute: Equatable {
        case physical(udid: String)
        case simulator
    }

    static func route(recordedUDID: String?) -> IOSAppsRoute {
        guard let recordedUDID else { return .simulator }
        return .physical(udid: recordedUDID)
    }

    /// **system も出す**(iOS 側と同じ形にする): 地図・ブラウザ等は `pm list packages -3`
    /// (ユーザーアプリのみ)には出ない。MCP の ft_list_apps が使う
    /// `AndroidDriver.listPackages(includeSystem:)` と同じものに揃える
    private static func androidApps(serial: String?) throws -> [ApiAppEntry] {
        let driver = try AndroidDriver(serial: serial)
        let packages = try driver.listPackages(includeSystem: true)
        return packages
            .map { ApiAppEntry(id: $0.id, name: $0.id, type: $0.isUser ? "user" : "system") }
            .sorted { $0.name < $1.name }
    }
}

/// fleetest api list-apps の 1 アプリ分。省略可能フィールドは無いため synthesized encode でよい
private struct ApiAppEntry: Encodable {
    let id: String
    let name: String
    let type: String
}

/// fleetest api list-apps の出力全体
private struct ApiListAppsOutput: Encodable {
    let apps: [ApiAppEntry]
    let platform: String
}
