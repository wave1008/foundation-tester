// LocalConfig.swift
// マシンローカル設定(~/.config/ftester/config.json)。
// マシン名(machines/<マシン名>.json の選択キー)とデフォルトプロジェクトを保持する。
// UserDefaults ではなくファイルにするのは、CLI / MCP の複数プロセスで
// ドメインを揃えて共有するため。リポジトリ内 .ftester/(実行時状態)とも役割を分離する。

import Foundation

public struct LocalConfig: Codable, Sendable, Equatable {
    /// このマシンの名前(profiles/machines/<マシン名>.json と一致させる)
    public var machineName: String?
    /// --project 省略時に使うプロジェクト名
    public var defaultProject: String?
    /// 呼び出し側が最後に選択した実行プロファイル名(プロジェクト毎)
    public var lastRunProfile: [String: String]?

    public init(machineName: String? = nil, defaultProject: String? = nil,
                lastRunProfile: [String: String]? = nil) {
        self.machineName = machineName
        self.defaultProject = defaultProject
        self.lastRunProfile = lastRunProfile
    }

    /// 設定ファイルの場所: $XDG_CONFIG_HOME/ftester/config.json(既定 ~/.config/ftester/config.json)
    public static func url(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
        }
        return base.appendingPathComponent("ftester/config.json")
    }

    /// 読み込み(無い・壊れている場合は空設定)
    public static func load(from url: URL = Self.url()) -> LocalConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(LocalConfig.self, from: data) else {
            return LocalConfig()
        }
        return config
    }

    public func save(to url: URL = Self.url()) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url)
    }

    /// 現在のマシン名。優先順位: FT_MACHINE 環境変数 > 設定ファイル > nil(未登録)
    public static func currentMachineName(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configURL: URL? = nil
    ) -> String? {
        if let env = environment["FT_MACHINE"], !env.isEmpty { return env }
        return load(from: configURL ?? Self.url(environment: environment)).machineName
    }
}
