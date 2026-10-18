// iOS 実機の最初のフレームを結果 JSON へ後から入れたとき(ResponseTracePatch)、Markdown レポート
// (reports/scenario-*.md)の同じステップの行にも同じ値を足す純粋な部分。
// 書式は FTDSL の ScenarioReportWriter.responseText の最初のフレームの部分と同一に保つ(`ScenarioReportWriterTests` が
// 同じ書式であることを突き合わせる)。行は `- ✅ 5. tap "#x" — 1.10s · ready 69 ms`。

import Foundation

public enum ResponseReportPatch {

    /// 行へ足す列。値も欠けた理由も無いときは nil(言えないときは何も足さない)
    static func firstFrameText(_ response: ResponseMeasurementRecord) -> String? {
        if let ms = response.firstFrameMs { return " · first frame \(ms) ms" }
        if let missing = response.firstFrameMissing { return " · first frame - (\(missing.rawValue))" }
        return nil
    }

    /// 行の末尾の `· ready …` の部分(あれば)。最初のフレームの列はその直前 = 時間列の直後に入る
    private static let readyTail = try! NSRegularExpression(
        pattern: #"( · ready (?:\d+ ms|- \([A-Za-z]+\)))?$"#)

    /// ステップ `stepIndex`(レポートの `N.`)の行へ最初のフレームの列を足したレポートの本文。
    /// 足すものが無い・その行が無い・既に `first frame` がある、のときは nil(呼び手は書き直さない)
    public static func insertingFirstFrame(markdown: String, stepIndex: Int,
                                           response: ResponseMeasurementRecord) -> String? {
        guard let text = firstFrameText(response) else { return nil }
        var lines = markdown.components(separatedBy: "\n")
        guard let at = lines.firstIndex(where: { isStepLine($0, index: stepIndex) }) else { return nil }
        let line = lines[at]
        guard !line.contains(" · first frame") else { return nil }
        let full = NSRange(line.startIndex..., in: line)
        guard let match = readyTail.firstMatch(in: line, range: full),
              let range = Range(match.range, in: line) else { return nil }
        lines[at] = String(line[..<range.lowerBound]) + text + String(line[range.lowerBound...])
        return lines.joined(separator: "\n")
    }

    /// `- <印> <index>. ` で始まる行か(印は ✅ 🔧 ❌ ⚠️ ❓。空白を含まない1語)
    static func isStepLine(_ line: String, index: Int) -> Bool {
        guard line.hasPrefix("- ") else { return false }
        let rest = line.dropFirst(2)
        guard let space = rest.firstIndex(of: " ") else { return false }
        return rest[rest.index(after: space)...].hasPrefix("\(index). ")
    }

    /// `before` → `after` で最初のフレームが入ったステップ(同じ添字の timeline の欄が変わったもの)をレポートへ反映した本文。
    /// 変わらなかったら nil
    public static func patching(markdown: String, before: ScenarioRunRecord, after: ScenarioRunRecord) -> String? {
        guard let old = before.timeline, let new = after.timeline, old.count == new.count else { return nil }
        var text = markdown
        var changed = false
        for (previous, current) in zip(old, new) where previous.index == current.index {
            guard let response = current.response, previous.response != response,
                  let patched = insertingFirstFrame(markdown: text, stepIndex: current.index, response: response)
            else { continue }
            text = patched
            changed = true
        }
        return changed ? text : nil
    }
}
