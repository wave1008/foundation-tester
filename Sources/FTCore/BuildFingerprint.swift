// BuildFingerprint.swift
// swift build --product は無変更でも ~2.6s かかる(SPM の依存グラフ再検証コスト)。
// mtime+size のフィンガープリント一致で「前回ビルド後に何も変わっていない」を検出し、
// ScenarioHost.build のビルドスキップ判定に使う。ファイル内容は読まない(速度優先)。

import CryptoKit
import Foundation

public enum BuildFingerprint {

    /// repoRoot/Package.swift・Package.resolved(あれば)・Sources/ 以下・scenariosDir 以下を
    /// 相対パスでソートした決定的順序で連結し SHA256 の hex 文字列を返す。
    /// Sources/ か scenariosDir が存在しない/列挙に失敗した場合は nil(常にビルドする安全側)。
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

        guard let sourcesEntries = enumerateEntries(
            repoRoot.appendingPathComponent("Sources"), repoRoot: repoRoot) else {
            return nil
        }
        guard let scenarioEntries = enumerateEntries(scenariosDir, repoRoot: repoRoot) else {
            return nil
        }
        entries += sourcesEntries
        entries += scenarioEntries
        entries.sort { $0.path < $1.path }

        var combined = ""
        for entry in entries {
            combined += "\(entry.path)\u{0}\(entry.mtimeMs)\u{0}\(entry.size)\n"
        }
        combined += toolchainIdentity ?? defaultToolchainIdentity()

        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
        repoRoot.appendingPathComponent(".ftester")
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
