// 自己修復(ロケータの指紋照合)で通ったシナリオを、合否を変えずに run の出口で知らせる。
// 治した回はステップの表示も結果も ✅ と同じで、exit code も 0 = CI からは選択子の腐りが見えなかった。
// 読み手は2つ: JUnit の `<system-out>`(`JUnitReportWriter`)と `fleetest run` の末尾の1行。文言は英語(CLI の出力)。
// 書き戻した結果の行は続けて `HealSourceWriteBack` が出す(書けなかった提案があるので、この行は書き戻しの有無を言わない)

import Foundation

public enum HealedScenarios {

    /// 自己修復で通ったか。**合格した記録だけ**(落ちた回は失敗として既に見える)
    public static func healed(_ record: ScenarioRunRecord) -> Bool {
        record.passed && record.steps.healed > 0
    }

    /// JUnit の `<system-out>` に載せる本文。治していなければ nil
    public static func note(for record: ScenarioRunRecord) -> String? {
        guard healed(record) else { return nil }
        var lines = ["passed only after self-healing: \(record.steps.healed) step(s) did not resolve with the"
            + " written selector and were matched by locator fingerprint (update the selector)"]
        for fix in record.fixSuggestions ?? [] {
            guard let old = fix.oldSelector, let new = fix.newSelector else { continue }
            let place = fix.file.map { file in fix.line.map { "\(file):\($0)" } ?? file } ?? "?"
            lines.append("\(place): change \"\(old)\" to \"\(new)\"")
        }
        if let report = record.reportPath { lines.append("report: \(report)") }
        return lines.joined(separator: "\n")
    }

    /// run の末尾に出す1行。治したシナリオが無ければ nil
    public static func summaryLine(records: [ScenarioRunRecord]) -> String? {
        let ids = Set(records.filter(healed).map(\.scenarioID))
        guard !ids.isEmpty else { return nil }
        return "⚠️ \(ids.count) scenario(s) passed only after self-healing — their selectors no longer match the"
            + " screen (each scenario report has the suggestions: steps.healed / fixSuggestions; what was written back"
            + " to the scenarios follows)"
    }
}
