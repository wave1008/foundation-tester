// 画像分類器の見本の採取と点検の中核。`fleetest vision capture/check`(CLI)と `ft_capture_element`(MCP)が
// 同じものを呼ぶ(MCP に2つ目の実装を書かない)。切り出しは呼び手が VisionClassifier.crop で行う
// = 推論と同じ切り方。

import CoreGraphics
import Foundation

public enum VisionSample {
    public static let knownClassifiers: Set<String> = [CheckStateClassifier.name, DefaultClassifier.name]

    public enum SaveError: LocalizedError {
        case invalidLabel(String)
        case notEncodable
        case conflict(String)
        public var errorDescription: String? {
            switch self {
            case .invalidLabel(let reason): return reason
            case .notEncodable: return "could not encode the cropped image as PNG"
            case .conflict(let reason): return "not saved: \(reason)"
            }
        }
    }

    /// label/name が `classifierFolder` の外へ出ないための下拵え。`..`/`.`/空の部品と絶対パスを断る
    /// (絶対パスは先頭が空の部品として弾かれる)。`save` の containment チェックとは独立の一次防御
    private static func pathIssue(_ value: String, kind: String) -> String? {
        let example = kind == "name" ? "\"capture-1.png\"" : "\"@i/Settings/[Camera Icon]\""
        if value.isEmpty { return "\(kind) must not be empty" }
        if value.hasPrefix("/") {
            return "\(kind) must be a relative path, not an absolute path (got \(value))"
        }
        for component in value.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty {
                return "\(kind) must not contain empty path components such as \"//\" (got \(value));"
                    + " example: \(example)"
            }
            if component == "." || component == ".." {
                return "\(kind) must not contain \".\" or \"..\" path components (got \(value));"
                    + " example: \(example)"
            }
        }
        return nil
    }

    /// A sample file name (the leaf, not the label folder) must be a single path component.
    public static func nameIssue(_ name: String) -> String? {
        if let issue = pathIssue(name, kind: "name") { return issue }
        if name.contains("/") { return "name must be a single file name, not a path (got \(name))" }
        return nil
    }

    /// `candidate` が `root` そのもの、または `root` の真下かを字面で確かめる。`labelIssue` の部品検査
    /// とは別の独立した判定(`save` の二次防御。`labelIssue` を経由しない直呼び出しでも効く)
    static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    /// 保存してから学習で気付く誤り(状態に写らないラベル・短いラベルの無いフォルダ)を先に断る
    public static func labelIssue(classifier: String, label: String) -> String? {
        guard knownClassifiers.contains(classifier) else {
            return "unknown classifier \(classifier) (use \(knownClassifiers.sorted().joined(separator: " or ")))"
        }
        if let issue = pathIssue(label, kind: "label") { return issue }
        let leaf = label.split(separator: "/").last.map(String.init) ?? label
        if classifier == CheckStateClassifier.name, CheckStateClassifier.state(forLabel: leaf) == nil {
            return "a CheckStateClassifier label must contain [ON], [OFF] or [INDETERMINATE] (got \(label))"
        }
        if !leaf.contains("[") || !leaf.hasSuffix("]") {
            return "the label folder must end with a bracketed name such as [Camera Icon] (got \(label));"
                + " imageIs matches the part from the last ["
        }
        return nil
    }

    public static func defaultFileName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "capture-\(formatter.string(from: date)).png"
    }

    /// 切り出した画像を見本として保存する。同じ短いラベルが別のフォルダにあれば(学習できない設定の誤り)、
    /// 保存した画像と作ったフォルダを戻して `SaveError.conflict`
    public static func save(_ image: CGImage, projectRoot: URL, classifier: String, label: String,
                            name: String?, now: Date = Date()) throws -> URL {
        if let issue = labelIssue(classifier: classifier, label: label) { throw SaveError.invalidLabel(issue) }
        if let name, let issue = nameIssue(name) { throw SaveError.invalidLabel(issue) }
        guard let data = VisionClassifier.pngData(image) else { throw SaveError.notEncodable }
        let classifierFolder = VisionClassifier.directory(projectRoot: projectRoot, name: classifier)
        let folder = classifierFolder.appendingPathComponent(label, isDirectory: true)
        guard isContained(folder, in: classifierFolder) else {
            throw SaveError.invalidLabel("label escapes the classifier folder (got \(label))")
        }
        // 断ったときに片付けるため、これから作るフォルダ(深い順)を控える。`deletingLastPathComponent()` は
        // "a/../../.." のような形に対して縮まらない不動点へ落ちて動かなくなることがある(元バグ:
        // `..` を含むラベルで無限ループ+created が際限なく伸びた)ので、不動点に着いたら打ち切る
        // (上の containment チェックで folder は既に classifierFolder の内側と確定しているので、
        // 通常経路ではこの不動点そのものに到達しない。直呼び出し等への保険として残す)
        var created: [URL] = []
        var cursor = folder
        while !FileManager.default.fileExists(atPath: cursor.path) {
            created.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name ?? defaultFileName(now))
        try data.write(to: file)
        do {
            _ = try VisionClassifier.trainingSet(at: classifierFolder)
        } catch {
            try? FileManager.default.removeItem(at: file)
            for directory in created { try? FileManager.default.removeItem(at: directory) }
            throw SaveError.conflict(ErrorText.user(error))
        }
        return file
    }

    /// 学習(必要なら)と点検の結果を行で返す。`ok` = 学習できて取り違えが無い
    public static func report(projectRoot: URL, classifier name: String) async -> (ok: Bool, lines: [String]) {
        let directory = VisionClassifier.directory(projectRoot: projectRoot, name: name)
        let set: VisionClassifier.TrainingSet?
        do {
            set = try VisionClassifier.trainingSet(at: directory)
        } catch {
            return (false, ["❌ \(name): \(ErrorText.user(error))"])
        }
        guard let set else {
            return (false, ["⚠️ \(name): needs sample images in at least two label folders (\(directory.path))"])
        }
        let model: VisionClassifier.Model
        do {
            model = try await VisionClassifier.load(
                set, cacheDirectory: VisionClassifier.cacheDirectory(projectRoot: projectRoot, name: name))
        } catch {
            return (false, ["❌ \(name): \(ErrorText.user(error))"])
        }
        let samples = set.labels.values.reduce(0) { $0 + $1.count }
        var lines = ["\(model.mismatches.isEmpty ? "✅" : "⚠️") \(name): \(set.labels.count) labels, \(samples) samples"]
        lines += set.labels.keys.sorted().map { "   \($0) (\(set.labels[$0]!.count))" }
        lines += model.mismatches.map { "   ⚠️ \(VisionClassifier.describe($0))" }
        return (model.mismatches.isEmpty, lines)
    }
}
