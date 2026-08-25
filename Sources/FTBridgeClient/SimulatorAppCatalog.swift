// iOS シミュレータのインストール済みアプリ一覧。`ftester api list-apps`(Sources/ftester/
// ApiListAppsCommand.swift)と MCP の ft_list_apps(Sources/ftester-mcp/DeviceInventory.swift)が
// 共有する。移設元は ApiListAppsCommand.swift の旧 private iosApps/bootedSimulatorUDID —
// 挙動は変えていない。
//
// parse は `xcrun simctl listapps <udid>` の OpenStep 形式 plist(トップレベルは
// [bundleID: 情報dict])を PropertyListSerialization でそのまま食わせる。

import Foundation
import FTCore

public enum SimulatorAppCatalog {

    public struct App: Sendable, Equatable {
        public let id: String
        public let name: String
        public let isUser: Bool

        public init(id: String, name: String, isUser: Bool) {
            self.id = id
            self.name = name
            self.isUser = isUser
        }
    }

    public enum SimulatorAppCatalogError: Error, LocalizedError, Equatable {
        case noBootedSimulator(String)
        case listAppsFailed(String)
        case unreadableOutput
        case unparsableOutput(String)
        case unexpectedFormat

        public var errorDescription: String? {
            switch self {
            case .noBootedSimulator(let name):
                return "no booted simulator found: \(name)"
            case .listAppsFailed(let detail):
                return "simctl listapps failed: \(detail)"
            case .unreadableOutput:
                return "cannot read the simctl listapps output"
            case .unparsableOutput(let detail):
                return "cannot parse the simctl listapps output: \(detail)"
            case .unexpectedFormat:
                return "unexpected simctl listapps output format"
            }
        }
    }

    /// `simctl listapps` の出力テキストを解析する(純粋関数・テスト可能)。
    /// ".xctrunner" で終わる id(XCUITest ランナー自身。実機で毎回混入する)は除外する。
    /// user が先、同じ type 内は表示名の小文字比較の昇順
    public static func parse(listAppsOutput: String) throws -> [App] {
        guard let data = listAppsOutput.data(using: .utf8) else {
            throw SimulatorAppCatalogError.unreadableOutput
        }
        let raw: Any
        do {
            raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw SimulatorAppCatalogError.unparsableOutput("\(error)")
        }
        guard let apps = raw as? [String: [String: Any]] else {
            throw SimulatorAppCatalogError.unexpectedFormat
        }

        let entries = apps.compactMap { id, info -> App? in
            guard !id.hasSuffix(".xctrunner") else { return nil }
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String) ?? id
            let isUser = (info["ApplicationType"] as? String) == "User"
            return App(id: id, name: name, isUser: isUser)
        }
        return entries.sorted { lhs, rhs in
            if lhs.isUser != rhs.isUser { return lhs.isUser }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
    }

    /// name に一致する Booted なシミュレータの UDID。名前指定の simctl は同名デバイス
    /// (Shutdown の複製等)に当たると失敗するため、先に UDID へ解決してから照会する。
    /// 同名 Booted が複数の場合は先頭を使う(SimulatorCatalog.devices() は起動中優先の
    /// 安定ソート済み)
    public static func bootedSimulatorUDID(named name: String) throws -> String {
        let matches = try SimulatorCatalog.devices().filter { $0.booted && $0.name == name }
        guard let first = matches.first else {
            throw SimulatorAppCatalogError.noBootedSimulator(name)
        }
        if matches.count > 1 {
            FileHandle.standardError.write(
                Data("Multiple booted simulators share this name. Using \(first.udid): \(name)\n".utf8))
        }
        return first.udid
    }

    /// udid のシミュレータへ `simctl listapps` を撃って解析する
    public static func apps(udid: String) throws -> [App] {
        let result = try Shell.run(["xcrun", "simctl", "listapps", udid])
        guard result.status == 0 else {
            throw SimulatorAppCatalogError.listAppsFailed(result.tail)
        }
        return try parse(listAppsOutput: result.output)
    }
}
