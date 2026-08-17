// LocalConfig.swift
// マシンローカル設定(~/.config/ftester/config.json)。
// デフォルトプロジェクト・実機署名・リモートホスト登録簿を保持する。
// **「このマシンの名前」は持たない**(2026-08-17 に廃止。理由は
// ProfileResolver.determineMachine の宣言 —— プロファイル名と機械の身元が1つの値に
// 載っていたため、マシンプロファイルを改名するとこの Mac の身元まで変わっていた)。
// UserDefaults ではなくファイルにするのは、CLI / MCP の複数プロセスで
// ドメインを揃えて共有するため。リポジトリ内 .ftester/(実行時状態)とも役割を分離する。

import Foundation

public struct LocalConfig: Codable, Sendable, Equatable {
    /// --project 省略時に使うプロジェクト名
    public var defaultProject: String?
    /// 呼び出し側が最後に選択した実行プロファイル名(プロジェクト毎)
    public var lastRunProfile: [String: String]?
    /// iOS 実機用の Apple Developer Team ID(Xcode の自動署名に渡す)。
    /// 実機ブリッジ(Runner/)のビルドにのみ使う。シミュレータでは不要
    public var developmentTeam: String?
    /// iOS 実機ブリッジの bundle id プレフィックス(既定 "com.example")。
    /// 既定のままだと他チームが登録済みの App ID と衝突して自動署名が失敗することがある
    public var bundleIDPrefix: String?
    /// `--host` の論理名 → ssh 実体の登録簿(docs/remote-runner.md §13)。VSCode 設定
    /// (`ftester.remote.hosts`)ではなくここに置くのは、①CLI が解決の主体になるため
    /// ②ワークスペース設定でディスパッチ先を差し替えられる余地を消すため(§15.2)
    public var remoteHosts: [RemoteHostEntry]?

    public init(defaultProject: String? = nil,
                lastRunProfile: [String: String]? = nil,
                developmentTeam: String? = nil, bundleIDPrefix: String? = nil,
                remoteHosts: [RemoteHostEntry]? = nil) {
        self.defaultProject = defaultProject
        self.lastRunProfile = lastRunProfile
        self.developmentTeam = developmentTeam
        self.bundleIDPrefix = bundleIDPrefix
        self.remoteHosts = remoteHosts
    }

    /// 実機署名の設定。優先順位: 環境変数 > 設定ファイル。
    /// team が nil なら実機ビルドはできない(呼び出し側が案内を出す)
    public static func codeSigning(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configURL: URL? = nil
    ) -> (team: String?, bundleIDPrefix: String) {
        let config = load(from: configURL ?? Self.url(environment: environment))
        let team = environment["FT_DEVELOPMENT_TEAM"].flatMap { $0.isEmpty ? nil : $0 }
            ?? config.developmentTeam.flatMap { $0.isEmpty ? nil : $0 }
        let prefix = environment["FT_BUNDLE_ID_PREFIX"].flatMap { $0.isEmpty ? nil : $0 }
            ?? config.bundleIDPrefix.flatMap { $0.isEmpty ? nil : $0 }
            ?? "com.example"
        return (team, prefix)
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

}
