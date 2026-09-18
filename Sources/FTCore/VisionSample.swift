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

    /// 保存してから学習で気付く誤り(状態に写らないラベル・短いラベルの無いフォルダ)を先に断る
    public static func labelIssue(classifier: String, label: String) -> String? {
        guard knownClassifiers.contains(classifier) else {
            return "unknown classifier \(classifier) (use \(knownClassifiers.sorted().joined(separator: " or ")))"
        }
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
        guard let data = VisionClassifier.pngData(image) else { throw SaveError.notEncodable }
        let classifierFolder = VisionClassifier.directory(projectRoot: projectRoot, name: classifier)
        let folder = classifierFolder.appendingPathComponent(label, isDirectory: true)
        // 断ったときに片付けるため、これから作るフォルダ(深い順)を控える
        var created: [URL] = []
        var cursor = folder
        while !FileManager.default.fileExists(atPath: cursor.path) {
            created.append(cursor)
            cursor = cursor.deletingLastPathComponent()
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
