// TestProject.swift
// テストプロジェクト = TestProjects/<name>/ 配下のシナリオ+プロファイル+レポートの器。
// SPM の executableTarget "ftester-scenarios-<name>"(path: TestProjects/<name>/scenarios)と 1:1 対応する。

import Foundation

public struct TestProject: Sendable, Hashable, Identifiable {
    public let name: String
    /// TestProjects/<name>/ の絶対 URL
    public let rootURL: URL

    public var id: String { name }

    public init(name: String, rootURL: URL) {
        self.name = name
        self.rootURL = rootURL
    }

    public var productName: String { "ftester-scenarios-\(name)" }

    /// **小文字 `scenarios/` が正**(2026-08-05 に `Scenarios/` から統一。他の器 —— profiles /
    /// reports / results / docs —— と揃える)。**旧名も受ける**: 既存の受け手のプロジェクトは
    /// `Scenarios/` のままで、macOS は大小同一視するので実害が出ないが、
    /// **大小を区別するボリュームでは解決できなくなる**ため明示的に見に行く
    public var scenariosDir: URL {
        let lower = rootURL.appendingPathComponent("scenarios")
        guard !FileManager.default.fileExists(atPath: lower.path) else { return lower }
        let legacy = rootURL.appendingPathComponent("Scenarios")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : lower
    }
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
                ? "(TestProjects/ is empty — create one with ftester project create)"
                : "(available: \(available.joined(separator: ", ")))"
            return "project not found: \(name) \(hint)"
        case .noProjects(let dir):
            return "no projects (\(dir.path)). Create one with: ftester project create <name>"
        case .ambiguous(let available):
            return "multiple projects exist. Pick one with --project, "
                + "or set defaultProject via ftester machine set / LocalConfig"
                + " (candidates: \(available.joined(separator: ", ")))"
        case .invalidName(let name):
            return "invalid project name: \(name) (allowed: letters, digits, _ and -, starting with a letter, digit or _. "
                + "It becomes an SPM target name, so Japanese is not allowed)"
        }
    }
}

public enum ProjectStore {
    public static func projectsDir(repoRoot: URL) -> URL {
        {
            let current = repoRoot.appendingPathComponent("TestProjects")
            guard !FileManager.default.fileExists(atPath: current.path) else { return current }
            // **旧名 `TestProjects/` も受ける**(2026-08-05 に改名。既存の受け手のリポジトリは
            // 旧名のままで、こちらは大小が違うので macOS でも解決できない)
            let legacy = repoRoot.appendingPathComponent("Projects")
            return FileManager.default.fileExists(atPath: legacy.path) ? legacy : current
        }()
    }

    /// TestProjects/ 直下のディレクトリを列挙(名前順)
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
