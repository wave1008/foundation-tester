// ReportWriter.swift
// 実行結果の Markdown レポート出力(失敗時のトリアージ・スクリーンショット付き)。

import Foundation

public enum ReportWriter {

    @discardableResult
    public static func write(result: RunResult, to dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())
        // 並列実行時の衝突回避: ミリ秒+フロー名スラッグをファイル名に含める
        let slug = FlowIO.suggestedFileName(for: result.flow)
            .replacingOccurrences(of: ".yaml", with: "")
            .prefix(24)
        let baseName = "run-\(stamp)-\(slug)"

        var md = "# テスト実行レポート\n\n"
        md += "- フロー: \(result.flow.name)\n"
        md += "- アプリ: \(result.flow.app)\n"
        if let goal = result.flow.goal { md += "- 目標: \(goal)\n" }
        md += "- 結果: \(result.passed ? "✅ 成功" : "❌ 失敗")\n"
        md += "- 日時: \(ISO8601DateFormatter().string(from: Date()))\n\n"

        md += "## ステップ\n\n"
        for step in result.steps {
            switch step.status {
            case .passed:
                md += "- ✅ \(step.index). \(step.description)\n"
            case .passedViaFallback(let locator):
                md += "- ✅ \(step.index). \(step.description)(フォールバック \(locator.summary) で解決)\n"
            case .healed(let locator):
                md += "- 🔧 \(step.index). \(step.description) → 自己修復: \(locator.summary)\n"
            case .failed(let reason):
                md += "- ❌ \(step.index). \(step.description)\n  - \(reason)\n"
            case .skipped(let reason):
                md += "- ⚠️ \(step.index). \(step.description)(スキップ: \(reason))\n"
            }
        }

        if let triage = result.triage {
            md += "\n## トリアージ(Foundation Models)\n\n"
            md += "- 分類: **\(triage.failureClass)**\n"
            md += "- 概要: \(triage.summary)\n"
            md += "- 修正案: \(triage.suggestedFix)\n"
        }

        if let screenshot = result.failureScreenshot {
            let imageName = "\(baseName).png"
            try screenshot.write(to: dir.appendingPathComponent(imageName))
            md += "\n## 失敗時のスクリーンショット\n\n![failure](\(imageName))\n"
        }

        let url = dir.appendingPathComponent("\(baseName).md")
        try md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
