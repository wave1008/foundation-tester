// ScenarioReportWriter.swift
// シナリオ実行結果の Markdown レポート(成否問わず常に出力)。
// 階層: シナリオ → scene → CAE セクション → ステップ。
// 命名規則・様式は旧 ReportWriter(フロー用)を踏襲する。

import Foundation
import FTCore

public enum ScenarioReportWriter {

    @discardableResult
    public static func write(record: ScenarioRecordData, to dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())
        // 並列実行時の衝突回避: ミリ秒+シナリオIDスラッグをファイル名に含める
        let baseName = "scenario-\(stamp)-\(slug(record.id))"

        var md = "# シナリオ実行レポート\n\n"
        md += "- シナリオ: \(record.id)"
        if !record.title.isEmpty { md += " — \(record.title)" }
        md += "\n"
        md += "- アプリ: \(record.app)\n"
        md += "- プラットフォーム: \(record.platform)\n"
        md += "- 結果: \(record.passed ? "✅ 成功" : "❌ 失敗")\n"
        md += "- 日時: \(ISO8601DateFormatter().string(from: Date()))\n"

        var screenshots: [(name: String, data: Data)] = []

        for scene in record.scenes {
            md += "\n## scene \(scene.number)"
            if !scene.title.isEmpty { md += ": \(scene.title)" }
            md += " — \(scene.passed ? "✅" : "❌")\n"

            var section: String? = "(未分類)"
            for step in scene.steps {
                if step.section != section {
                    section = step.section
                    if let section { md += "\n### \(section)\n\n" } else { md += "\n" }
                }
                md += line(for: step)
            }

            if let triage = scene.triage {
                md += "\n### トリアージ(Foundation Models)\n\n"
                md += "- 分類: **\(triage.failureClass)**\n"
                md += "- 概要: \(triage.summary)\n"
                md += "- 修正案: \(triage.suggestedFix)\n"
            }

            if let screenshot = scene.failureScreenshot {
                let imageName = "\(baseName)-scene\(scene.number).png"
                screenshots.append((imageName, screenshot))
                md += "\n### 失敗時のスクリーンショット\n\n![failure](\(imageName))\n"
            }
        }

        if !record.fixSuggestions.isEmpty {
            md += "\n## 修正提案\n\n"
            for suggestion in record.fixSuggestions {
                md += "- \(suggestion.isStrong ? "💡" : "・") \(suggestion.message)\n"
            }
            md += "\n(ソースは自動書換されません。上記を反映するとヒールキャッシュ非依存に戻ります)\n"
        }

        for (name, data) in screenshots {
            try data.write(to: dir.appendingPathComponent(name))
        }

        let url = dir.appendingPathComponent("\(baseName).md")
        try md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func line(for step: DSLStepRecord) -> String {
        let location = step.file.isEmpty ? "" : "(\(URL(fileURLWithPath: step.file).lastPathComponent):\(step.line))"
        // 時間列(Phase 0 計測基盤)。durationMs 欠測(dry-run・スキップ等)時は空欄
        let duration = durationText(step.durationMs)
        switch step.status {
        case .passed:
            return "- ✅ \(step.index). \(step.description)\(duration)\n"
        case .passedViaFallback(let locator):
            return "- ✅ \(step.index). \(step.description)(フォールバック \(locator.summary) で解決)\(duration)\n"
        case .healed(let locator):
            return "- 🔧 \(step.index). \(step.description) → 自己修復: \(locator.summary) \(location)\(duration)\n"
        case .failed(let reason):
            return "- ❌ \(step.index). \(step.description) \(location)\(duration)\n  - \(reason)\n"
        case .skipped(let reason):
            return "- ⚠️ \(step.index). \(step.description)(スキップ: \(reason))\(duration)\n"
        }
    }

    /// durationMs → 表示用の時間列テキスト(例: " — 0.83s"。欠測時は空文字)
    static func durationText(_ durationMs: Int?) -> String {
        guard let durationMs else { return "" }
        return String(format: " — %.2fs", Double(durationMs) / 1000)
    }

    /// シナリオ ID からファイル名用スラッグを作る(日本語可、記号は _ に)
    static func slug(_ text: String) -> String {
        var sanitized = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) ||
               scalar.properties.isIdeographic ||
               (0x3040...0x30FF).contains(Int(scalar.value)) {  // ひらがな・カタカナ
                sanitized.unicodeScalars.append(scalar)
            } else {
                sanitized.append("_")
            }
        }
        while sanitized.contains("__") {
            sanitized = sanitized.replacingOccurrences(of: "__", with: "_")
        }
        let trimmed = String(sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "_")).prefix(24))
        return trimmed.isEmpty ? "scenario" : trimmed
    }
}
