// ScenarioFolders.swift
// シナリオのフォルダグルーピング(Projects/<name>/Scenarios/ 直下のサブディレクトリ、1 階層のみ)。
// SPM ターゲットは path 以下を再帰的にコンパイルするため、フォルダを作っても Package.swift の
// 変更は不要(_disabled/ だけが exclude)。シナリオ ID(クラス名.メソッド名)はフォルダと無関係で、
// 「シナリオの移動」は実体としてはクラスを定義する .swift ファイルの移動になる。

import Foundation

public enum ScenarioFoldersError: Error, LocalizedError {
    case invalidName(String)
    case alreadyExists(String)
    case notFound(String)
    case notEmpty(String)
    case destinationOccupied(file: String, folder: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let reason):
            return "フォルダ名が不正です: \(reason)"
        case .alreadyExists(let name):
            return "同名のフォルダまたはファイルが既にあります: \(name)"
        case .notFound(let name):
            return "フォルダが見つかりません: \(name)"
        case .notEmpty(let name):
            return "フォルダが空ではないため削除できません: \(name)"
        case .destinationOccupied(let file, let folder):
            let dest = folder.map { "フォルダ \($0)" } ?? "Scenarios 直下"
            return "\(dest) に同名のファイルが既にあります: \(file)"
        }
    }
}

public enum ScenarioFolders {

    /// コンパイル対象外の退避場所(Package.swift の exclude と対)。フォルダとして扱わない
    public static let reservedNames: Set<String> = ["_disabled"]

    /// Scenarios/ 直下のフォルダ名一覧(1 階層のみ。_disabled と隠しディレクトリは除外、名前順)
    public static func list(scenariosDir: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: scenariosDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { !reservedNames.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// クラス名 → 定義している .swift の URL。Scenarios/ 以下を走査する(_disabled と隠しは除外)。
    /// シナリオ一覧(クラス名.メソッド名)とファイルを対応付けてフォルダ表示・移動に使う
    public static func classFileMap(scenariosDir: URL) -> [String: URL] {
        var map: [String: URL] = [:]
        for file in swiftFiles(under: scenariosDir) {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for name in classNames(inSource: source) {
                map[name] = file
            }
        }
        return map
    }

    /// ファイルが属するフォルダ名(Scenarios/ 直下なら nil)
    public static func folderName(of file: URL, scenariosDir: URL) -> String? {
        let base = scenariosDir.standardizedFileURL.pathComponents
        let path = file.standardizedFileURL.pathComponents
        guard path.count > base.count + 1, Array(path.prefix(base.count)) == base else {
            return nil
        }
        return path[base.count]
    }

    /// フォルダ名の検証。戻り値: エラーメッセージ(nil = 有効)
    public static func validateName(_ name: String) -> String? {
        if name.isEmpty {
            return "フォルダ名を入力してください"
        }
        if name.contains("/") || name.contains(":") {
            return "「/」「:」は使えません"
        }
        if name.hasPrefix(".") {
            return "先頭に「.」は使えません"
        }
        if reservedNames.contains(name) {
            return "\(name) は予約されています(コンパイル対象外の退避場所)"
        }
        return nil
    }

    /// フォルダを作成する(Scenarios/ 直下、1 階層のみ)
    @discardableResult
    public static func create(name: String, scenariosDir: URL) throws -> URL {
        if let reason = validateName(name) {
            throw ScenarioFoldersError.invalidName(reason)
        }
        let url = scenariosDir.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            throw ScenarioFoldersError.alreadyExists(name)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// シナリオファイルをフォルダへ移動する(folder = nil は Scenarios/ 直下へ)。
    /// 移動後の URL を返す(移動不要ならそのまま返す)
    @discardableResult
    public static func move(file: URL, toFolder folder: String?,
                            scenariosDir: URL) throws -> URL {
        let destDir: URL
        if let folder {
            destDir = scenariosDir.appendingPathComponent(folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: destDir.path) else {
                throw ScenarioFoldersError.notFound(folder)
            }
        } else {
            destDir = scenariosDir
        }
        let dest = destDir.appendingPathComponent(file.lastPathComponent)
        guard dest.standardizedFileURL.path != file.standardizedFileURL.path else {
            return file
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            throw ScenarioFoldersError.destinationOccupied(
                file: file.lastPathComponent, folder: folder)
        }
        try FileManager.default.moveItem(at: file, to: dest)
        return dest
    }

    /// フォルダの名前を変更する
    public static func rename(_ name: String, to newName: String, scenariosDir: URL) throws {
        if let reason = validateName(newName) {
            throw ScenarioFoldersError.invalidName(reason)
        }
        let src = scenariosDir.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw ScenarioFoldersError.notFound(name)
        }
        let dest = scenariosDir.appendingPathComponent(newName, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw ScenarioFoldersError.alreadyExists(newName)
        }
        try FileManager.default.moveItem(at: src, to: dest)
    }

    /// 空のフォルダを削除する(.DS_Store 等の隠しファイルだけなら空とみなす)
    public static func delete(_ name: String, scenariosDir: URL) throws {
        let url = scenariosDir.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ScenarioFoldersError.notFound(name)
        }
        let visible = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard visible.isEmpty else {
            throw ScenarioFoldersError.notEmpty(name)
        }
        try FileManager.default.removeItem(at: url)
    }

    /// 外部変更検知用のディレクトリ署名。.swift のパス+更新時刻+サイズと、
    /// フォルダ構成(空フォルダ含む)を並べたもの。署名が変わらない変更
    /// (_disabled/ の中身、.md 等の非ソース、レポート出力など)では再ビルドしない
    public static func directorySignature(scenariosDir: URL) -> [String] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey,
                                         .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: scenariosDir, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else {
            return []
        }
        let basePath = scenariosDir.standardizedFileURL.path
        var parts: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(basePath + "/")
                ? String(path.dropFirst(basePath.count + 1)) : path
            if values?.isDirectory == true {
                if reservedNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                parts.append("dir:\(relative)")
            } else if url.pathExtension == "swift" {
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                parts.append("file:\(relative):\(mtime):\(values?.fileSize ?? 0)")
            }
        }
        return parts.sorted()
    }

    // MARK: - 内部

    /// Scenarios/ 以下の .swift を列挙する(_disabled と隠しディレクトリはスキップ)
    private static func swiftFiles(under dir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                ?? false
            if isDirectory {
                if reservedNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if url.pathExtension == "swift" {
                files.append(url.standardizedFileURL)
            }
        }
        return files
    }

    /// ソース中の class 宣言のクラス名(日本語識別子可)。
    /// 行頭(+修飾子・属性)に続く class だけを拾い、コメント行の混入を避ける
    static func classNames(inSource source: String) -> [String] {
        let pattern = #"(?m)^[ \t]*(?:(?:@[\p{L}\p{N}_]+(?:\([^)]*\))?|public|open|internal|package|final)[ \t]+)*class[ \t]+([\p{L}\p{N}_]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }
}
