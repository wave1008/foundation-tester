// PackageManifestEditor.swift
// Package.swift のマーカー区間(fleetest projects begin/end)を全置換で更新する。
// プロジェクト毎の executableTarget "fleetest-scenarios-<name>" はこの区間に自動生成され、
// fleetest project create/sync だけが書き換える(手編集禁止)。
// 書換後は swift package dump-package で構文検証し、失敗時は元の内容へロールバックする。
// 受け手が足す依存はマーカー区間の外の辞書 `fleetestScenarioDependencies`(プロジェクト名 → 依存)に書き、
// 生成するターゲットはそれを参照するだけ(区間の中へ手で足すと sync が消す)。

import Foundation

public enum PackageManifestEditorError: Error, LocalizedError {
    case manifestNotFound(URL)
    case markersNotFound(URL)
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .manifestNotFound(let url):
            return "Package.swift not found: \(url.path)"
        case .markersNotFound(let url):
            return "Package.swift has no marker section: \(url.path)\n"
                + "Add these two lines inside the targets array:\n"
                + "        \(PackageManifestEditor.beginMarker)\n"
                + "        \(PackageManifestEditor.endMarker)"
        case .validationFailed(let log):
            return "Package.swift failed verification and was rolled back:\n\(log)"
        }
    }
}

public enum PackageManifestEditor {
    public static let beginMarker =
        "// === fleetest projects begin(fleetest project create/sync が自動生成。手編集禁止)==="
    public static let endMarker =
        "// === fleetest projects end ==="

    /// 受け手が編集する辞書の名前。生成するターゲットはこれを名指しで参照するので、改名すると既存の
    /// 受け手の Package.swift が壊れる(`ensureExtraDependenciesDeclaration` が足すのは新しい名前だけ)
    public static let extraDependenciesName = "fleetestScenarioDependencies"

    /// 辞書が無い Package.swift に足す宣言。受け手の Package.swift に残るので英語で書く
    static let extraDependenciesDeclaration = """
        // Extra dependencies for each project's scenario target: "<project name>": [dependencies].
        // fleetest project sync keeps this declaration. Declare the packages themselves in
        // `dependencies:` of the Package as usual.
        let \(extraDependenciesName): [String: [Target.Dependency]] = [:]


        """

    /// 1 プロジェクト分の executableTarget エントリ(targets 配列内、8 スペースインデント)。
    /// external = true(fleetest init が生成する受け手のパッケージ)では FTScenarioRunner/FTDSL を
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
                    name: "fleetest-scenarios-\(name)",
                    dependencies: \(deps) + (\(extraDependenciesName)["\(name)"] ?? []),
                    path: "TestProjects/\(name)/scenarios",
                    exclude: ["_disabled"]
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
        updated = try ensureExtraDependenciesDeclaration(in: updated, manifestURL: manifestURL)
        let unknown = unknownExtraDependencyKeys(in: updated, projectNames: projectNames)
        if !unknown.isEmpty {
            ConsoleOut.err("⚠️ \(extraDependenciesName) in \(manifestURL.path) has keys that are not projects "
                + "(their dependencies are not used): \(unknown.joined(separator: ", "))")
        }
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

    /// 辞書の宣言が無ければ `let package` の直前(無ければ `import PackageDescription` の直後)へ足す。
    /// 生成したターゲットが名指しで参照するので、無いままだと Package.swift がコンパイルできない
    static func ensureExtraDependenciesDeclaration(in content: String, manifestURL: URL) throws -> String {
        guard content.range(of: #"\b(let|var)\s+\#(extraDependenciesName)\b"#,
                            options: .regularExpression) == nil else { return content }
        var updated = content
        if let packageLine = updated.range(of: #"(?m)^let\s+package\s*="#, options: .regularExpression) {
            updated.insert(contentsOf: extraDependenciesDeclaration, at: packageLine.lowerBound)
        } else if let importLine = updated.range(of: #"(?m)^import\s+PackageDescription[^\n]*\n"#,
                                                 options: .regularExpression) {
            updated.insert(contentsOf: "\n" + extraDependenciesDeclaration, at: importLine.upperBound)
        } else {
            throw PackageManifestEditorError.validationFailed(
                "Could not find where to declare \(extraDependenciesName) in \(manifestURL.path)"
                    + " (no `let package =` and no `import PackageDescription` line)")
        }
        return updated
    }

    /// 辞書のキーのうち登録済みのプロジェクトでないもの(綴り違いは黙って依存が空になるので警告する)。
    /// 宣言の行から、行頭が `]` の行(辞書の閉じ)までの各行の行頭の `"キー":` を拾う。式で組み立てた
    /// 辞書は読めないが、そのときは何も拾わない(誤った警告は出さない)
    static func unknownExtraDependencyKeys(in content: String, projectNames: [String]) -> [String] {
        let lines = content.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.range(of: #"^\s*(let|var)\s+\#(extraDependenciesName)\b"#, options: .regularExpression) != nil
        }) else { return [] }
        if lines[start].contains("[:]") { return [] }
        var keys: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("]") { break }
            guard let match = line.range(of: #"^\s*"[^"]+"\s*:"#, options: .regularExpression) else { continue }
            let key = line[match].trimmingCharacters(in: .whitespaces).dropFirst()
                .prefix(while: { $0 != "\"" })
            keys.append(String(key))
        }
        let known = Set(projectNames)
        return keys.filter { !known.contains($0) }
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
            pattern: #"name:\s*"fleetest-scenarios-([A-Za-z0-9_-]+)""#)
        let range = NSRange(sectionText.startIndex..., in: sectionText)
        return regex.matches(in: sectionText, range: range).compactMap { match in
            Range(match.range(at: 1), in: sectionText).map { String(sectionText[$0]) }
        }.sorted()
    }
}
