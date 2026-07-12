// VSCode拡張のライブ操作パネル(アプリ切り替え)向け: デバイスのインストール済みアプリ一覧を
// JSON で stdout に出力する(ftester api list-apps)。stdout には結果1行の JSON だけを出す
// (診断は stderr のみ。ApiListDevicesCommand.swift と同じ流儀)。
//
// iOS: `xcrun simctl listapps <デバイス名>` の出力(OpenStep形式 plist、トップレベルは
// [bundleID: 情報dict])をそのまま PropertyListSerialization でパースする。ApplicationType が
// "User" 以外は "system" 扱い。".xctrunner" で終わる id(XCUITestランナー自身)は一覧から除外する
// (実機で毎回このエントリが混入するため)。

import ArgumentParser
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

struct ApiListApps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-apps",
        abstract: "デバイスのインストール済みアプリ一覧をJSONでstdoutに出力する(診断は stderr のみ)")

    @OptionGroup var driverOptions: DriverOptions

    func run() async throws {
        let apps: [ApiAppEntry]
        switch driverOptions.platform {
        case "ios":
            apps = try await Self.iosApps(port: driverOptions.port)
        case "android":
            apps = try Self.androidApps(serial: driverOptions.serial)
        default:
            throw ValidationError("platform は ios / android のいずれかです: \(driverOptions.platform)")
        }

        let output = ApiListAppsOutput(apps: apps, platform: driverOptions.platform)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }

    /// user が先、同じ type 内は表示名の小文字比較でソートする
    private static func iosApps(port: UInt16) async throws -> [ApiAppEntry] {
        let status = try await BridgeClient(port: port, timeoutSeconds: 10).status()
        // 名前指定の simctl は同名デバイス(Shutdown の複製等)に当たると失敗するため、
        // Booted かつ同名のデバイスの UDID に解決してから照会する。
        let udid = try bootedSimulatorUDID(named: status.device)
        let result = try Shell.run(["xcrun", "simctl", "listapps", udid])
        guard result.status == 0 else {
            throw ValidationError("simctl listapps が失敗しました: \(result.tail)")
        }
        guard let data = result.output.data(using: .utf8) else {
            throw ValidationError("simctl listapps の出力を読み取れません")
        }
        let raw: Any
        do {
            raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw ValidationError("simctl listapps の出力をパースできませんでした: \(error)")
        }
        guard let apps = raw as? [String: [String: Any]] else {
            throw ValidationError("simctl listapps の出力形式が想定外です")
        }

        let entries = apps.compactMap { id, info -> ApiAppEntry? in
            guard !id.hasSuffix(".xctrunner") else { return nil }
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String) ?? id
            let type = (info["ApplicationType"] as? String) == "User" ? "user" : "system"
            return ApiAppEntry(id: id, name: name, type: type)
        }
        return entries.sorted { lhs, rhs in
            if lhs.type != rhs.type { return lhs.type == "user" }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
    }

    /// ブリッジ /status のデバイス名 → Booted な同名シミュレータの UDID。同名 Booted が複数の
    /// 場合は先頭を使う(SimulatorCatalog.devices() は起動中優先の安定ソート済み)。
    private static func bootedSimulatorUDID(named name: String) throws -> String {
        let matches = try SimulatorCatalog.devices().filter { $0.booted && $0.name == name }
        guard let first = matches.first else {
            throw ValidationError("起動中のシミュレータが見つかりません: \(name)")
        }
        if matches.count > 1 {
            FileHandle.standardError.write(
                Data("同名の起動中シミュレータが複数あります。\(first.udid) を使用します: \(name)\n".utf8))
        }
        return first.udid
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
