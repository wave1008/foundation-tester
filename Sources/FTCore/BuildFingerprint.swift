// BuildFingerprint.swift
// swift build --product は無変更でも ~2.6s かかる(SPM の依存グラフ再検証コスト)。
// mtime+size のフィンガープリント一致で「前回ビルド後に何も変わっていない」を検出し、
// ScenarioHost.build のビルドスキップ判定に使う。ファイル内容は読まない(速度優先)。

import CryptoKit
import Foundation

public enum BuildFingerprint {

    /// repoRoot/Package.swift・Package.resolved(あれば)・Sources/ 以下(あれば)・scenariosDir 以下・
    /// **パス依存(`.package(path:)`)の先の同じ3点**を、パスでソートした決定的順序で連結し
    /// SHA256 の hex 文字列を返す。
    /// **Sources/ が無いだけでは nil にしない** —— 外部パッケージ構成(受け手・ランナー機の WORK_DIR)は
    /// Sources/ を持たず、ツール本体はパス依存の先に居る。nil にすると毎回 swift build を払う。
    /// 列挙に失敗した・scenariosDir が無い・パス依存の先に Sources/ が無い場合は nil(常にビルドする安全側)。
    /// url 依存の先は見ない(リビジョンは Package.resolved が固定する)。
    /// Package.swift/Package.resolved が無い場合は単にエントリをスキップするだけで nil にはしない。
    public static func compute(
        repoRoot: URL, scenariosDir: URL, toolchainIdentity: String? = nil
    ) -> String? {
        var entries: [(path: String, mtimeMs: Int64, size: Int64)] = []

        if let entry = fileEntry(repoRoot.appendingPathComponent("Package.swift"), repoRoot: repoRoot) {
            entries.append(entry)
        }
        if let entry = fileEntry(
            repoRoot.appendingPathComponent("Package.resolved"), repoRoot: repoRoot) {
            entries.append(entry)
        }

        let sourcesDir = repoRoot.appendingPathComponent("Sources")
        if FileManager.default.fileExists(atPath: sourcesDir.path) {
            guard let sourcesEntries = enumerateEntries(sourcesDir, repoRoot: repoRoot) else {
                return nil
            }
            entries += sourcesEntries
        }
        guard let scenarioEntries = enumerateEntries(scenariosDir, repoRoot: repoRoot) else {
            return nil
        }
        entries += scenarioEntries

        for dependencyRoot in pathDependencyRoots(repoRoot: repoRoot) {
            for name in ["Package.swift", "Package.resolved"] {
                if let entry = fileEntry(
                    dependencyRoot.appendingPathComponent(name), repoRoot: repoRoot) {
                    entries.append(entry)
                }
            }
            guard let dependencyEntries = enumerateEntries(
                dependencyRoot.appendingPathComponent("Sources"), repoRoot: repoRoot) else {
                return nil
            }
            entries += dependencyEntries
        }
        entries.sort { $0.path < $1.path }

        var combined = ""
        for entry in entries {
            combined += "\(entry.path)\u{0}\(entry.mtimeMs)\u{0}\(entry.size)\n"
        }
        combined += toolchainIdentity ?? defaultToolchainIdentity()

        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// repoRoot/Package.swift が宣言するパス依存の先(相対パスは repoRoot 基準)。
    /// 抽出の規則は Scripts/install.sh の TOOL_ROOT 解決(sed)と同じ形。行コメントの中は読まない
    static func pathDependencyRoots(repoRoot: URL) -> [URL] {
        guard let manifest = try? String(
            contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8),
              let pattern = try? NSRegularExpression(
                pattern: #"\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?path:\s*"([^"]+)""#) else {
            return []
        }
        var roots: [URL] = []
        for line in manifest.split(separator: "\n") {
            let code = String(line.components(separatedBy: "//").first ?? "")
            let range = NSRange(code.startIndex..., in: code)
            for match in pattern.matches(in: code, range: range) {
                guard let pathRange = Range(match.range(at: 1), in: code) else { continue }
                let path = String(code[pathRange])
                roots.append(path.hasPrefix("/")
                    ? URL(fileURLWithPath: path)
                    : repoRoot.appendingPathComponent(path).standardizedFileURL)
            }
        }
        return roots
    }

    /// Xcode 切替・更新でフィンガープリントが変わるようにする: macOS ベータ更新後に Xcode を
    /// 揃えずビルド済みバイナリを使い続けると FoundationModels の ABI 不整合で dyld クラッシュする
    /// 既知の罠があり、ビルドスキップでそれを温存しないための識別子。
    public static func defaultToolchainIdentity() -> String {
        let linkPath = (try? FileManager.default.destinationOfSymbolicLink(
            atPath: "/var/db/xcode_select_link"))
            ?? ProcessInfo.processInfo.environment["DEVELOPER_DIR"]

        guard let linkPath else { return "unknown|unknown" }

        // linkPath は通常 .../Xcode.app/Contents/Developer。1 階層上げた
        // .../Xcode.app/Contents/version.plist の mtime で Xcode 本体の更新を検知する
        let versionPlist = URL(fileURLWithPath: linkPath).deletingLastPathComponent()
            .appendingPathComponent("version.plist")
        let versionPlistMs: String
        if let attrs = try? FileManager.default.attributesOfItem(atPath: versionPlist.path),
           let date = attrs[.modificationDate] as? Date {
            versionPlistMs = String(Int64(date.timeIntervalSince1970 * 1000))
        } else {
            versionPlistMs = "unknown"
        }
        return "\(linkPath)|\(versionPlistMs)"
    }

    public static func stored(productName: String, repoRoot: URL) -> String? {
        guard let data = try? Data(contentsOf: fingerprintURL(productName: productName, repoRoot: repoRoot)),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 書き込み失敗は握りつぶす(次回ビルドされるだけなので安全側)
    public static func store(_ fingerprint: String, productName: String, repoRoot: URL) {
        let url = fingerprintURL(productName: productName, repoRoot: repoRoot)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fingerprint.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func fingerprintURL(productName: String, repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".fleetest")
            .appendingPathComponent("build-fingerprint-\(productName).txt")
    }

    private static func fileEntry(
        _ url: URL, repoRoot: URL
    ) -> (path: String, mtimeMs: Int64, size: Int64)? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = values.contentModificationDate, let size = values.fileSize else {
            return nil
        }
        return (relativePath(of: url, repoRoot: repoRoot),
                Int64(mtime.timeIntervalSince1970 * 1000), Int64(size))
    }

    /// ディレクトリ再帰列挙。列挙またはリソース値取得に失敗したら nil(呼び出し側で
    /// ビルドを常に実行させるため)。ドットファイル/ドットディレクトリは
    /// skipsHiddenFiles に加えて明示チェックでスキップする
    private static func enumerateEntries(
        _ dir: URL, repoRoot: URL
    ) -> [(path: String, mtimeMs: Int64, size: Int64)]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }) else {
            return nil
        }

        var entries: [(path: String, mtimeMs: Int64, size: Int64)] = []
        for case let item as URL in enumerator {
            if enumerationFailed { return nil }
            if item.lastPathComponent.hasPrefix(".") { continue }
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { return nil }
            if values.isDirectory == true { continue }
            guard let mtime = values.contentModificationDate, let size = values.fileSize else {
                return nil
            }
            entries.append((relativePath(of: item, repoRoot: repoRoot),
                            Int64(mtime.timeIntervalSince1970 * 1000), Int64(size)))
        }
        if enumerationFailed { return nil }
        return entries
    }

    private static func relativePath(of url: URL, repoRoot: URL) -> String {
        let fullPath = url.path
        let rootPath = repoRoot.path.hasSuffix("/") ? repoRoot.path : repoRoot.path + "/"
        guard fullPath.hasPrefix(rootPath) else { return fullPath }
        return String(fullPath.dropFirst(rootPath.count))
    }
}
