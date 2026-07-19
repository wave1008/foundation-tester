// TestProject.swift
// テストプロジェクト = Projects/<name>/ 配下のシナリオ+プロファイル+レポートの器。
// SPM の executableTarget "ftester-scenarios-<name>"(path: Projects/<name>/Scenarios)と 1:1 対応する。

import Foundation

public struct TestProject: Sendable, Hashable, Identifiable {
    public let name: String
    /// Projects/<name>/ の絶対 URL
    public let rootURL: URL

    public var id: String { name }

    public init(name: String, rootURL: URL) {
        self.name = name
        self.rootURL = rootURL
    }

    public var productName: String { "ftester-scenarios-\(name)" }

    public var scenariosDir: URL { rootURL.appendingPathComponent("Scenarios") }
    public var generatedDir: URL { scenariosDir.appendingPathComponent("Generated") }
    public var disabledDir: URL { scenariosDir.appendingPathComponent("_disabled") }
    public var profilesDir: URL { rootURL.appendingPathComponent("profiles") }
    public var appsDir: URL { profilesDir.appendingPathComponent("apps") }
    public var machinesDir: URL { profilesDir.appendingPathComponent("machines") }
    public var runsDir: URL { profilesDir.appendingPathComponent("runs") }
    public var reportsDir: URL { rootURL.appendingPathComponent("reports") }
    public var docsDir: URL { rootURL.appendingPathComponent("docs") }
    /// テスト設計の元資料(仕様・観点)置き場。シナリオの根拠ドキュメント
    public var testbasesDir: URL { docsDir.appendingPathComponent("testbases") }
    /// プロジェクト別の実行時状態(ヒールキャッシュ等)
    public var stateDir: URL { rootURL.appendingPathComponent(".ftester") }
}

public enum ProjectStoreError: Error, LocalizedError {
    case notFound(name: String, available: [String])
    case noProjects(projectsDir: URL)
    case ambiguous(available: [String])
    case invalidName(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name, let available):
            let hint = available.isEmpty
                ? "(Projects/ が空です。ftester project create で作成してください)"
                : "(利用可能: \(available.joined(separator: ", ")))"
            return "プロジェクトが見つかりません: \(name) \(hint)"
        case .noProjects(let dir):
            return "プロジェクトがありません(\(dir.path))。ftester project create <name> で作成してください"
        case .ambiguous(let available):
            return "プロジェクトが複数あります。--project で指定するか、"
                + "ftester machine set / LocalConfig の defaultProject を設定してください"
                + "(候補: \(available.joined(separator: ", ")))"
        case .invalidName(let name):
            return "プロジェクト名が不正です: \(name)(使用可能: 英数字・_・- で、先頭は英数字か _。"
                + "SPM のターゲット名になるため日本語は使えません)"
        }
    }
}

public enum ProjectStore {
    public static func projectsDir(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent("Projects")
    }

    /// Projects/ 直下のディレクトリを列挙(名前順)
    public static func all(repoRoot: URL) -> [TestProject] {
        let dir = projectsDir(repoRoot: repoRoot)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { TestProject(name: $0.lastPathComponent, rootURL: $0.standardizedFileURL) }
            .sorted { $0.name < $1.name }
    }

    /// プロジェクト解決。name 指定 → 一致するもの。
    /// 省略時: 1 つならそれ → defaultProject(LocalConfig)→ エラー(候補一覧付き)
    public static func find(_ name: String?, repoRoot: URL,
                            defaultProject: String? = nil) throws -> TestProject {
        let projects = all(repoRoot: repoRoot)
        if let name {
            guard let project = projects.first(where: { $0.name == name }) else {
                throw ProjectStoreError.notFound(name: name, available: projects.map(\.name))
            }
            return project
        }
        if projects.isEmpty {
            throw ProjectStoreError.noProjects(projectsDir: projectsDir(repoRoot: repoRoot))
        }
        if projects.count == 1 { return projects[0] }
        if let defaultProject,
           let project = projects.first(where: { $0.name == defaultProject }) {
            return project
        }
        throw ProjectStoreError.ambiguous(available: projects.map(\.name))
    }

    /// SPM のターゲット/モジュール名になるためのバリデーション
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_][A-Za-z0-9_-]*$", options: .regularExpression) != nil
    }
}
