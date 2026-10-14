// マシン側 config.json の `hooks` 欄(docs/remote-runner.md §17 の「スクリプト(Seatbelt の中)」)。
// 読むファイルは `ScenarioSandbox.machineSettingsURL()` = 実ホームの固定パス
// (`XDG_CONFIG_HOME` で別の設定へ向けて書ける場所を広げさせない)。

import Foundation

public struct HooksSettings: Codable, Sendable, Equatable {
    /// スクリプトが書いてよい追加の場所(絶対パスか `~/` 始まり。読み込み時に実ホームで展開する)
    public var writablePaths: [String]?

    public init(writablePaths: [String]? = nil) {
        self.writablePaths = writablePaths
    }

    public static let knownKeys: Set<String> = ["writablePaths"]

    public enum ConfigError: Error, LocalizedError, Equatable {
        case unreadable(String, detail: String)
        case unknownKeys(String, keys: [String])
        case invalidValue(String, key: String, reason: String)
        case overlapsProtectedLocation(path: String, protected: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path, let detail):
                return "hooks settings in \(path) cannot be read: \(detail)"
            case .unknownKeys(let path, let keys):
                return "hooks settings in \(path) have unknown key(s): \(keys.joined(separator: ", "))"
                    + " (known: \(HooksSettings.knownKeys.sorted().joined(separator: ", ")))"
            case .invalidValue(let path, let key, let reason):
                return "hooks settings in \(path): \"\(key)\" \(reason)"
            case .overlapsProtectedLocation(let path, let protected):
                return "hooks.writablePaths entry \(path.debugDescription) overlaps \(protected), which is run or"
                    + " interpreted outside the sandbox — a script must not be able to write there"
            }
        }
    }

    /// ファイルが無い・`hooks` 欄が無い = nil。壊れている・未知のキー・不正な値は投げる
    /// (綴りの誤りを黙って無視しない)。`writablePaths` の `~/` は `home` で展開して返す
    public static func load(configURL: URL = ScenarioSandbox.machineSettingsURL(),
                            home: String = ScenarioSandbox.realHome()) throws -> HooksSettings? {
        let path = configURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: try Data(contentsOf: configURL))
        } catch {
            throw ConfigError.unreadable(path, detail: "\(error)")
        }
        guard let root = json as? [String: Any] else {
            throw ConfigError.unreadable(path, detail: "not a JSON object")
        }
        guard let section = root["hooks"] else { return nil }
        guard let object = section as? [String: Any] else {
            throw ConfigError.unreadable(path, detail: "\"hooks\" is not an object")
        }
        let unknown = object.keys.filter { !knownKeys.contains($0) }.sorted()
        guard unknown.isEmpty else { throw ConfigError.unknownKeys(path, keys: unknown) }

        var settings = HooksSettings()
        if let raw = object["writablePaths"] {
            guard let list = raw as? [String] else {
                throw ConfigError.invalidValue(path, key: "writablePaths",
                                               reason: "must be an array of absolute paths (or paths starting with \"~/\")")
            }
            if let bad = list.first(where: { $0.isEmpty || !($0.hasPrefix("/") || $0.hasPrefix("~/")) }) {
                throw ConfigError.invalidValue(
                    path, key: "writablePaths",
                    reason: "entry \(bad.debugDescription) is not an absolute path (write /… or ~/…)")
            }
            settings.writablePaths = list.map { ScenarioSandbox.expandTilde($0, home: home) }
        }
        return settings
    }

    /// 書ける場所に「枠の外で実行・解釈されるもの」の置き場を含めさせない。**実体パス**で比べ、
    /// 等しい・entry が protected の中・protected が entry の中のどれかなら投げる
    /// (外側の指定は中の protected まで書けるようにするので、内側と同じく断る)
    public static func validate(writablePaths: [String],
                                protected: [(label: String, path: String)]) throws {
        for entry in writablePaths {
            let real = ScenarioSandbox.canonicalPath(entry)
            for place in protected {
                let guarded = ScenarioSandbox.canonicalPath(place.path)
                if real == guarded || real.hasPrefix(guarded + "/") || guarded.hasPrefix(real + "/") {
                    throw ConfigError.overlapsProtectedLocation(path: entry, protected: place.label)
                }
            }
        }
    }
}
