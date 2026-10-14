// マシン側 config.json の `services` 欄(docs/remote-runner.md §17)。
// 読むファイルは `LocalConfig.url()` が返す場所(環境変数で別の場所へ向ける口は新設しない)。

import Foundation

public struct ServicesSettings: Codable, Sendable, Equatable {
    public enum Runtime: String, Codable, Sendable { case docker, apple }

    /// nil = 使えるものがちょうど1つのときだけ自動。
    public var runtime: Runtime?
    /// 読み取り専用のビルド元(絶対パス。`~` は展開しない)。
    public var buildSources: [String]?
    /// 機械の LAN アドレス(IPv4)。名指し。自動では選ばない。
    public var publishForPhysicalDevices: String?

    public init(runtime: Runtime? = nil, buildSources: [String]? = nil,
                publishForPhysicalDevices: String? = nil) {
        self.runtime = runtime
        self.buildSources = buildSources
        self.publishForPhysicalDevices = publishForPhysicalDevices
    }

    public static let knownKeys: Set<String> = ["runtime", "buildSources", "publishForPhysicalDevices"]

    public enum ConfigError: Error, LocalizedError, Equatable {
        case unreadable(String, detail: String)
        case unknownKeys(String, keys: [String])
        case invalidValue(String, key: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path, let detail):
                return "services settings in \(path) cannot be read: \(detail)"
            case .unknownKeys(let path, let keys):
                return "services settings in \(path) have unknown key(s): \(keys.joined(separator: ", "))"
                    + " (known: \(ServicesSettings.knownKeys.sorted().joined(separator: ", ")))"
            case .invalidValue(let path, let key, let reason):
                return "services settings in \(path): \"\(key)\" \(reason)"
            }
        }
    }

    /// ファイルが無い・`services` 欄が無い = nil。壊れている・未知のキー・不正な値は投げる
    /// (`LocalConfig.load` の「壊れていたら空設定」には倒さない = 綴りの誤りを黙って無視しない)。
    public static func load(configURL: URL = LocalConfig.url()) throws -> ServicesSettings? {
        let path = configURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data: Data
        let json: Any
        do {
            data = try Data(contentsOf: configURL)
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigError.unreadable(path, detail: "\(error)")
        }
        guard let root = json as? [String: Any] else {
            throw ConfigError.unreadable(path, detail: "not a JSON object")
        }
        guard let section = root["services"] else { return nil }
        guard let object = section as? [String: Any] else {
            throw ConfigError.unreadable(path, detail: "\"services\" is not an object")
        }
        let unknown = object.keys.filter { !knownKeys.contains($0) }.sorted()
        guard unknown.isEmpty else { throw ConfigError.unknownKeys(path, keys: unknown) }

        var settings = ServicesSettings()
        if let raw = object["runtime"] {
            guard let text = raw as? String, let runtime = Runtime(rawValue: text) else {
                throw ConfigError.invalidValue(path, key: "runtime", reason: "must be \"docker\" or \"apple\"")
            }
            settings.runtime = runtime
        }
        if let raw = object["buildSources"] {
            guard let list = raw as? [String] else {
                throw ConfigError.invalidValue(path, key: "buildSources", reason: "must be an array of absolute paths")
            }
            if let bad = list.first(where: { !$0.hasPrefix("/") }) {
                throw ConfigError.invalidValue(
                    path, key: "buildSources",
                    reason: "entry \(bad.debugDescription) is not an absolute path (\"~\" is not expanded)")
            }
            settings.buildSources = list
        }
        if let raw = object["publishForPhysicalDevices"] {
            guard let text = raw as? String, isIPv4(text) else {
                throw ConfigError.invalidValue(path, key: "publishForPhysicalDevices",
                                               reason: "must be an IPv4 address such as 192.168.1.20")
            }
            settings.publishForPhysicalDevices = text
        }
        return settings
    }

    /// 点4つの10進数(各 0...255・先頭 0 は許さない = 8進と読む実装との食い違いを避ける)。
    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  part == "0" || !part.hasPrefix("0"), let n = Int(part) else { return false }
            return n <= 255
        }
    }
}
