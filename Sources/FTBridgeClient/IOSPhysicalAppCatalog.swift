// iOS 実機のインストール済みアプリ一覧。`xcrun devicectl device info apps` の result.apps を
// パースする。SimulatorAppCatalog(シミュレータ側)と対になる。
//   - devicectl の JSON 出力だけが「バージョン付きで安定」と保証されている出力
//     (人間向けの表形式は不安定なので使わない。IOSPhysicalDeviceCatalog.swift と同じ方針)
//   - **`--include-all-apps` を必ず付ける**: 既定はビルド由来(builtByDeveloper)だけの一覧で、
//     App Store 経由のアプリが漏れる(実測: 有り287件・無し7件)
//   - user/system の分類は `bundleIdentifier` の "com.apple." 接頭辞で行う。`url` の
//     `/System` 接頭辞では分類できない(Safari・Apple マップも他アプリと同じ
//     `/private/var/containers/...` に居る。実測で確認)

import Foundation
import FTCore

public enum IOSPhysicalAppCatalog {

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

    public enum IOSPhysicalAppCatalogError: Error, LocalizedError, Equatable {
        case devicectlFailed(udid: String, detail: String)
        case unparsableOutput(udid: String)

        public var errorDescription: String? {
            switch self {
            case .devicectlFailed(let udid, let detail):
                return "xcrun devicectl device info apps failed for physical iOS device \(udid): \(detail)"
                    + " (check the USB/WiFi connection, \"Trust This Computer\" and Developer Mode)"
            case .unparsableOutput(let udid):
                return "devicectl returned installed apps for \(udid) in an unexpected JSON shape"
            }
        }
    }

    /// udid の実機のインストール済みアプリ一覧。`--json-output` はこのサブコマンドで
    /// stdout("-")を受け付けないため、一時ファイルへ書かせてから読む(list devices と違う点)
    public static func apps(udid: String) throws -> [App] {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-devicectl-apps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let result = try Shell.run(
            ["xcrun", "devicectl", "device", "info", "apps", "--device", udid,
             "--include-all-apps", "--json-output", outputURL.path], timeout: 30)
        guard result.status == 0, let data = try? Data(contentsOf: outputURL) else {
            throw IOSPhysicalAppCatalogError.devicectlFailed(udid: udid, detail: result.tail)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = parse(json: json) else {
            throw IOSPhysicalAppCatalogError.unparsableOutput(udid: udid)
        }
        return apps
    }

    /// JSON(`devicectl device info apps --json-output` の全体)→ アプリ一覧の純粋関数
    /// (実機無しでテストできる)。形が違えば nil(呼び手が devicectlFailed とは別のエラーにする)。
    /// user が先、同じ区分内は表示名の小文字比較の昇順(SimulatorAppCatalog.parse と揃える)
    static func parse(json: [String: Any]) -> [App]? {
        guard let apps = (json["result"] as? [String: Any])?["apps"] as? [[String: Any]] else {
            return nil
        }
        let entries = apps.compactMap { entry -> App? in
            guard let id = entry["bundleIdentifier"] as? String else { return nil }
            return App(id: id, name: (entry["name"] as? String) ?? id, isUser: !isSystemApp(id))
        }
        return entries.sorted { lhs, rhs in
            if lhs.isUser != rhs.isUser { return lhs.isUser }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
    }

    /// Apple 提供アプリの判定。実測でこの規則は妥当(Safari/Apple マップは system 側、
    /// Google マップや利用者のアプリは user 側 —— この端末では非 Apple が 206 件)
    static func isSystemApp(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("com.apple.")
    }
}
