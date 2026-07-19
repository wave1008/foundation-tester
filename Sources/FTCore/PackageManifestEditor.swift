// PackageManifestEditor.swift
// Package.swift のマーカー区間(ftester projects begin/end)を全置換で更新する。
// プロジェクト毎の executableTarget "ftester-scenarios-<name>" はこの区間に自動生成され、
// ftester project create/sync だけが書き換える(手編集禁止)。
// 書換後は swift package dump-package で構文検証し、失敗時は元の内容へロールバックする。

import Foundation

public enum PackageManifestEditorError: Error, LocalizedError {
    case manifestNotFound(URL)
    case markersNotFound(URL)
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .manifestNotFound(let url):
            return "Package.swift が見つかりません: \(url.path)"
        case .markersNotFound(let url):
            return "Package.swift にマーカー区間がありません: \(url.path)\n"
                + "targets 配列内に以下の 2 行を追加してください:\n"
                + "        \(PackageManifestEditor.beginMarker)\n"
                + "        \(PackageManifestEditor.endMarker)"
        case .validationFailed(let log):
            return "Package.swift の検証に失敗したため元に戻しました:\n\(log)"
        }
    }
}

public enum PackageManifestEditor {
    public static let beginMarker =
        "// === ftester projects begin(ftester project create/sync が自動生成。手編集禁止)==="
    public static let endMarker =
        "// === ftester projects end ==="

    /// 1 プロジェクト分の executableTarget エントリ(targets 配列内、8 スペースインデント)。
    /// external = true(ftester init が生成する受け手のパッケージ)では FTScenarioRunner/FTDSL を
    /// 内部ターゲット参照ではなく `.product(name:..., package: "foundation-tester")` で引く。
    public static func targetEntry(for name: String, external: Bool = false) -> String {
        // deps は literal に補間されるため 8 スペースのストリップ対象外。最終ファイルの
        // フィールド(12 スペース)に合わせ .product を 16、閉じ ] を 12 スペースで直書きする。
        let deps = external
            ? "[\n"
                + "                .product(name: \"FTScenarioRunner\", package: \"foundation-tester\"),\n"
                + "                .product(name: \"FTDSL\", package: \"foundation-tester\"),\n"
                + "            ]"
            : #"["FTScenarioRunner", "FTDSL"]"#
        return """
                .executableTarget(
                    name: "ftester-scenarios-\(name)",
                    dependencies: \(deps),
                    path: "Projects/\(name)/Scenarios",
                    exclude: ["_disabled"],
                    swiftSettings: swift5Mode
                ),
        """
    }

    /// マーカー区間全体(begin/end 行込み)を生成する
    public static func section(projectNames: [String], external: Bool = false) -> String {
        var lines = ["        \(beginMarker)"]
        for name in projectNames.sorted() {
            lines.append(targetEntry(for: name, external: external))
        }
        lines.append("        \(endMarker)")
        return lines.joined(separator: "\n")
    }

    /// マーカー区間を projectNames の内容で全置換する。
    /// verify = true なら swift package dump-package で検証し、失敗時はロールバックして throw。
    /// external は targetEntry と同義(受け手のパッケージなら .product 参照)。
    public static func updateProjects(manifestURL: URL, projectNames: [String],
                                      external: Bool = false, verify: Bool = true) throws {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PackageManifestEditorError.manifestNotFound(manifestURL)
        }
        let original = try String(contentsOf: manifestURL, encoding: .utf8)
        guard let beginRange = original.range(of: beginMarker),
              let endRange = original.range(of: endMarker),
              beginRange.upperBound <= endRange.lowerBound else {
            throw PackageManifestEditorError.markersNotFound(manifestURL)
        }
        let start = original.lineRange(for: beginRange).lowerBound
        let end = original.lineRange(for: endRange).upperBound
        var updated = original
        updated.replaceSubrange(start..<end,
                                with: section(projectNames: projectNames, external: external) + "\n")
        guard updated != original else { return }

        try updated.write(to: manifestURL, atomically: true, encoding: .utf8)
        if verify {
            let result = try Shell.run(["swift", "package", "dump-package"],
                                       cwd: manifestURL.deletingLastPathComponent())
            guard result.status == 0 else {
                try original.write(to: manifestURL, atomically: true, encoding: .utf8)
                throw PackageManifestEditorError.validationFailed(result.tail)
            }
        }
    }

    /// マーカー区間に登録済みのプロジェクト名を抽出する(名前順)
    public static func registeredProjects(manifestURL: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PackageManifestEditorError.manifestNotFound(manifestURL)
        }
        let content = try String(contentsOf: manifestURL, encoding: .utf8)
        guard let beginRange = content.range(of: beginMarker),
              let endRange = content.range(of: endMarker),
              beginRange.upperBound <= endRange.lowerBound else {
            throw PackageManifestEditorError.markersNotFound(manifestURL)
        }
        let sectionText = String(content[beginRange.upperBound..<endRange.lowerBound])
        let regex = try NSRegularExpression(
            pattern: #"name:\s*"ftester-scenarios-([A-Za-z0-9_-]+)""#)
        let range = NSRange(sectionText.startIndex..., in: sectionText)
        return regex.matches(in: sectionText, range: range).compactMap { match in
            Range(match.range(at: 1), in: sectionText).map { String(sectionText[$0]) }
        }.sorted()
    }
}
