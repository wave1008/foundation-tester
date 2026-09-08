// ProjectMutation.swift
// fleetest project copy/rename/delete の fs 操作 + Package.swift 再登録。
// CLI(Sources/fleetest/ProjectCommands.swift)側には引数の受け取り・出力・LocalConfig の
// 追随だけを残す(LocalConfig は機械グローバルな ~/.config/fleetest/config.json を書くため、
// 単体テストが触れる FTCore にはここでは触れない)。

import Foundation

public enum ProjectMutationError: Error, LocalizedError {
    case sameName(String)
    case trashResultUnavailable(URL)

    public var errorDescription: String? {
        switch self {
        case .sameName(let name):
            return "the new name is the same as the current name: \(name)"
        case .trashResultUnavailable(let url):
            return "moved to the Trash but could not determine the resulting location: \(url.path)"
        }
    }
}

public enum ProjectMutation {

    /// コピー元から除外する相対パス(プロジェクトルート基準、先頭一致)。実行の産物とキャッシュを
    /// 複製すると、複製先の初回実行の判定(履歴・ヒール等)がコピー元のものと混ざる
    private static let excludedDirectoryPrefixes = [
        "reports/", "results/", ".fleetest/", ".ftester/",
        "scenarios/_runfile/", "workspace/apps/",
    ]
    private static let excludedNames: Set<String> = [".DS_Store"]

    @discardableResult
    public static func copy(source: String, newName: String, repoRoot: URL,
                            verify: Bool = true) throws -> TestProject {
        guard ProjectStore.isValidName(newName) else {
            throw ProjectStoreError.invalidName(newName)
        }
        let projects = ProjectStore.all(repoRoot: repoRoot)
        guard let sourceProject = projects.first(where: { $0.name == source }) else {
            throw ProjectStoreError.notFound(name: source, available: projects.map(\.name))
        }
        let newProject = TestProject(
            name: newName,
            rootURL: ProjectStore.projectsDir(repoRoot: repoRoot).appendingPathComponent(newName))
        guard ProjectScaffold.canScaffold(into: newProject.rootURL) else {
            throw ProjectScaffoldError.alreadyExists(newProject.rootURL)
        }

        try copyTree(from: sourceProject.rootURL, to: newProject.rootURL)
        // 除外した workspace/apps/ を空で戻す(規約フォルダはプロジェクトの一部として常に要る)
        try WorkspaceScaffold.ensureDefault(projectRoot: newProject.rootURL)
        try registerAll(repoRoot: repoRoot, verify: verify)
        return newProject
    }

    @discardableResult
    public static func rename(oldName: String, newName: String, repoRoot: URL,
                              verify: Bool = true) throws -> TestProject {
        guard oldName != newName else {
            throw ProjectMutationError.sameName(oldName)
        }
        guard ProjectStore.isValidName(newName) else {
            throw ProjectStoreError.invalidName(newName)
        }
        let projects = ProjectStore.all(repoRoot: repoRoot)
        guard let project = projects.first(where: { $0.name == oldName }) else {
            throw ProjectStoreError.notFound(name: oldName, available: projects.map(\.name))
        }
        let newRoot = ProjectStore.projectsDir(repoRoot: repoRoot).appendingPathComponent(newName)
        guard ProjectScaffold.canScaffold(into: newRoot) else {
            throw ProjectScaffoldError.alreadyExists(newRoot)
        }

        try FileManager.default.moveItem(at: project.rootURL, to: newRoot)
        try registerAll(repoRoot: repoRoot, verify: verify)
        return TestProject(name: newName, rootURL: newRoot)
    }

    @discardableResult
    public static func delete(name: String, repoRoot: URL, verify: Bool = true) throws -> URL {
        let projects = ProjectStore.all(repoRoot: repoRoot)
        guard let project = projects.first(where: { $0.name == name }) else {
            throw ProjectStoreError.notFound(name: name, available: projects.map(\.name))
        }

        // removeItem は取り消せない。受け手のシナリオが入っているディレクトリなので
        // ゴミ箱へ逃がし、誤削除に対して復元の余地を残す
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: project.rootURL, resultingItemURL: &trashedURL)
        try registerAll(repoRoot: repoRoot, verify: verify)
        guard let resolved = trashedURL as URL? else {
            throw ProjectMutationError.trashResultUnavailable(project.rootURL)
        }
        return resolved
    }

    private static func registerAll(repoRoot: URL, verify: Bool) throws {
        try PackageManifestEditor.updateProjects(
            manifestURL: repoRoot.appendingPathComponent("Package.swift"),
            projectNames: ProjectStore.all(repoRoot: repoRoot).map(\.name),
            external: ProjectScaffold.isExternalPackage(repoRoot: repoRoot),
            verify: verify)
    }

    /// FileManager.copyItem は丸ごとコピーしか選べないため、除外パスを飛ばして自前で歩く。
    /// 除外の判定はプロジェクトルートからの相対パスの**先頭一致**(深い階層の同名ディレクトリ、
    /// 例 `scenarios/foo/reports/` を巻き添えにしない)
    private static func copyTree(from sourceRoot: URL, to destRoot: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
        try copyContents(sourceDir: sourceRoot, destDir: destRoot, sourceRoot: sourceRoot)
    }

    private static func copyContents(sourceDir: URL, destDir: URL, sourceRoot: URL) throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        for entry in entries {
            let name = entry.lastPathComponent
            guard !excludedNames.contains(name) else { continue }
            let isDirectory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
            let relative = relativePath(of: entry, from: sourceRoot) + (isDirectory ? "/" : "")
            guard !excludedDirectoryPrefixes.contains(where: { relative.hasPrefix($0) }) else { continue }

            let dest = destDir.appendingPathComponent(name)
            if isDirectory {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                try copyContents(sourceDir: entry, destDir: dest, sourceRoot: sourceRoot)
            } else {
                try fm.copyItem(at: entry, to: dest)
            }
        }
    }

    private static func relativePath(of url: URL, from base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath) else { return path }
        var relative = String(path.dropFirst(basePath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }
}
