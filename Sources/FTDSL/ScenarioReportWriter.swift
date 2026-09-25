// シナリオ実行結果の Markdown レポート(成否問わず常に出力)。
// 階層: シナリオ → scene → CAE セクション → ステップ。

import Foundation
import FTCore

public enum ScenarioReportWriter {

    /// notices: シナリオ全体に関わる注意書き(例: 実機の画面が実行中に消えていた)。
    /// 判定はこの関数の外(呼び出し側)で確定させてから渡すこと —— ここでは事実をそのまま載せるだけ。
    /// 既存の呼び手は空のまま(挙動不変)
    @discardableResult
    public static func write(record: ScenarioRecordData, to dir: URL, notices: [String] = []) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())
        // 並列実行時の衝突回避: ミリ秒+シナリオIDスラッグをファイル名に含める
        let baseName = "scenario-\(stamp)-\(slug(record.id))"

        var md = "# Scenario run report\n\n"
        md += "- Scenario: \(record.id)"
        if !record.title.isEmpty { md += " — \(record.title)" }
        md += "\n"
        md += "- App: \(record.app)\n"
        md += "- Platform: \(record.platform)\n"
        if let deviceLine = deviceLine(name: record.deviceName, identifier: record.deviceIdentifier) {
            md += "- Device: \(deviceLine)\n"
        }
        md += "- Result: \(record.passed ? "✅ passed" : "❌ failed")\n"
        md += "- Timestamp: \(ISO8601DateFormatter().string(from: Date()))\n"
        for notice in notices {
            md += "\n> ⚠️ \(notice)\n"
        }

        var screenshots: [(name: String, data: Data)] = []
        var evidenceScenes: [FailureEvidence.Scene] = []

        for scene in record.scenes {
            md += "\n## scene \(scene.number)"
            if !scene.title.isEmpty { md += ": \(scene.title)" }
            md += " — \(scene.passed ? "✅" : "❌")\n"

            var section: String? = "(uncategorized)"
            for step in scene.steps {
                if step.section != section {
                    section = step.section
                    if let section { md += "\n### \(section)\n\n" } else { md += "\n" }
                }
                md += line(for: step)
                if let data = step.screenshotData {
                    let stem = step.screenshotLabel ?? "screenshot"
                    let stemNoExt = stem.hasSuffix(".png") ? String(stem.dropLast(4)) : stem
                    let imageName = "\(baseName)-scene\(scene.number)-step\(step.index)-\(slug(stemNoExt)).png"
                    screenshots.append((imageName, data))
                    md += "<a href=\"\(imageName)\"><img src=\"\(imageName)\" width=\"320\"/></a>\n\n"
                }
            }

            if !scene.failureAppProcess.isEmpty {
                // window の覆いより前に置く: プロセスが無いなら、その先の容疑は無意味な情報になる
                md += "\n> ⚠️ **The app process is not running** (it may have crashed): "
                md += scene.failureAppProcess.joined(separator: " / ")
                md += "\n"
            }
            if !scene.failureForegroundWindows.isEmpty {
                // 要素一覧より前に置く: アプリが覆われていたなら、要素の中身を読む前にこれが答え
                md += "\n> ⚠️ **Another window is in front of the app**: "
                md += scene.failureForegroundWindows.joined(separator: ", ")
                md += ". Input may have been swallowed by it, so `tap` can report success while nothing happened"
                md += " (windows owned by other processes never appear in the app element list).\n"
            }
            if let elements = scene.failureElements, !elements.isEmpty {
                // 直すための一次情報。スクショより先に置く(モデルは PNG から #id を読めない)
                md += "\n<details><summary>Element list at the moment of failure</summary>\n\n```\n"
                md += elements
                md += "\n```\n</details>\n"
            }
            let failureImageName = scene.failureScreenshot.map { _ in "\(baseName)-scene\(scene.number).png" }
            if scene.failureElements != nil || failureImageName != nil
                || !scene.failureForegroundWindows.isEmpty || !scene.failureAppProcess.isEmpty {
                // 白フレームは凍結でもアラート中でも証跡として無効 = 判定を挟まず evidenceBlank をそのまま渡す
                evidenceScenes.append(FailureEvidence.Scene(
                    number: scene.number, title: scene.title,
                    elements: scene.failureElements.flatMap { $0.isEmpty ? nil : $0 },
                    screenshotFile: failureImageName, screenshotBlank: scene.evidenceBlank,
                    foregroundWindows: scene.failureForegroundWindows,
                    appProcess: scene.failureAppProcess))
            }
            if let screenshot = scene.failureScreenshot, let imageName = failureImageName {
                screenshots.append((imageName, screenshot))
                // 縮小表示+クリックでフルサイズ(markdown プレビューはインライン HTML を描画する。
                // ![...]() 直埋めだと端末縦解像度のまま表示され確認しづらい)
                md += "\n### Screenshot at failure (click for full size)\n\n"
                // 「凍結」と書くかは凍結の判定(markDeviceFrozen)と同じ FrozenFrameJudgement で決める
                if FrozenFrameJudgement.shouldMarkFrozen(evidenceBlank: scene.evidenceBlank,
                                                         systemAlertPresent: scene.failureUnderSystemAlert) {
                    md += "\n> ⚠️ The evidence screenshot is a blank frame (frozen device display), so it is not valid evidence.\n"
                } else if scene.evidenceBlank {
                    md += "\n> ⚠️ The evidence screenshot is a blank frame because a system alert was in front of"
                        + " the app (the in-app screenshot goes blank while the app is inactive), so it is not"
                        + " valid evidence. This is not counted as a frozen display.\n"
                }
                md += "<a href=\"\(imageName)\"><img src=\"\(imageName)\" width=\"320\"/></a>\n"
            }
        }

        if !record.fixSuggestions.isEmpty {
            md += "\n## Suggested fixes\n\n"
            for suggestion in record.fixSuggestions {
                md += "- \(suggestion.isStrong ? "💡" : "・") \(suggestion.message)\n"
            }
            md += "\n(Sources are not rewritten automatically. Applying the above removes the dependency on self-healing.)\n"
        }

        for (name, data) in screenshots {
            try data.write(to: dir.appendingPathComponent(name))
        }

        let url = dir.appendingPathComponent("\(baseName).md")
        try md.write(to: url, atomically: true, encoding: .utf8)
        // 読み手(ft_run_scenario)は証跡が無くても失敗を報告できるので、書けなくても md は返す
        if !evidenceScenes.isEmpty {
            try? FailureEvidence(scenes: evidenceScenes).write(forReport: url)
        }
        return url
    }

    /// 実行デバイス行のテキスト(論理名+括弧で技術識別子)。両方 nil なら行自体を省略するため nil を返す
    static func deviceLine(name: String?, identifier: String?) -> String? {
        switch (name, identifier) {
        case let (name?, identifier?): return "\(name) (\(identifier))"
        case let (name?, nil): return name
        case let (nil, identifier?): return "(\(identifier))"
        case (nil, nil): return nil
        }
    }

    static func line(for step: DSLStepRecord) -> String {
        let location = step.file.isEmpty ? "" : "(\(URL(fileURLWithPath: step.file).lastPathComponent):\(step.line))"
        // 時間列。durationMs 欠測(dry-run・スキップ等)時は空欄
        let duration = durationText(step.durationMs)
        switch step.status {
        case .passed:
            return "- ✅ \(step.index). \(step.description)\(duration)\n"
        case .passedViaFallback(let locator):
            return "- ✅ \(step.index). \(step.description) (resolved via fallback \(locator.summary))\(duration)\n"
        case .healed(let locator):
            return "- 🔧 \(step.index). \(step.description) → self-healed: \(locator.summary) \(location)\(duration)\n"
        case .failed(let reason):
            return "- ❌ \(step.index). \(step.description) \(location)\(duration)\n  - \(reason)\n"
        case .skipped(let reason):
            return "- ⚠️ \(step.index). \(step.description) (skipped: \(reason))\(duration)\n"
        case .inconclusive(let reason):
            return "- ❓ \(step.index). \(step.description) (inconclusive: \(reason))\(duration)\n"
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
