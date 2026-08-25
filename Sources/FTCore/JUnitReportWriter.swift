// JUnitReportWriter.swift
// run の結果(ScenarioRunRecord)→ JUnit XML。CI(GitHub Actions / Jenkins 等)のテストレポート
// 取り込み用で、`fleetest run --junit <path>` が run 終了時に書き出す。
// 3つの実行経路(逐次 / --ports 並列 / --profile 並列)すべてが RunRecorder 経由で
// runDir/scenarios/*.json を書くため、そこを唯一の入力にする(経路ごとの集計を持たない)。
//
// 対応: testsuite = シナリオのクラス(scenarioID の最初の "." より前)、
//       testcase = シナリオ、time = durationMs/1000。
//       skipped 判定は recordSkipped の形(全ステップ skipped・failed 0・不合格)と対。

import Foundation

public enum JUnitReportWriter {

    /// records から JUnit XML(testsuites)を組み立てる。
    /// 出力は決定的(クラス名・scenarioID でソート)。records が空でも妥当な XML を返す
    public static func xml(project: String, records: [ScenarioRunRecord]) -> String {
        let sorted = records.sorted { ($0.scenarioID, $0.startedAt) < ($1.scenarioID, $1.startedAt) }
        let grouped = Dictionary(grouping: sorted) { className(of: $0.scenarioID) }
        let classNames = grouped.keys.sorted()

        var suites: [String] = []
        var totals = Counts()
        for name in classNames {
            let records = grouped[name] ?? []
            let counts = Counts(records: records)
            totals.add(counts)
            var lines: [String] = []
            lines.append("  <testsuite name=\"\(escape(name))\" tests=\"\(counts.tests)\""
                + " failures=\"\(counts.failures)\" errors=\"0\" skipped=\"\(counts.skipped)\""
                + " time=\"\(seconds(counts.totalMs))\">")
            for record in records {
                lines.append(testcase(record, className: name))
            }
            lines.append("  </testsuite>")
            suites.append(lines.joined(separator: "\n"))
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites name="\(escape(project))" tests="\(totals.tests)" failures="\(totals.failures)"\
         errors="0" skipped="\(totals.skipped)" time="\(seconds(totals.totalMs))">
        \(suites.joined(separator: "\n"))
        </testsuites>
        """ + "\n"
    }

    /// scenarioID の最初の "." より前(クラス名)。"." が無ければ全体
    static func className(of scenarioID: String) -> String {
        scenarioID.firstIndex(of: ".").map { String(scenarioID[..<$0]) } ?? scenarioID
    }

    /// recordSkipped が書く形(全ステップ skipped・failed 0・不合格)= 実行に至らなかったシナリオ。
    /// 途中まで走って中断したシナリオは skipped>0 でも failed>0 なので failure 扱いになる
    static func isSkipped(_ record: ScenarioRunRecord) -> Bool {
        !record.passed && record.steps.failed == 0
            && record.steps.total > 0 && record.steps.skipped == record.steps.total
    }

    /// 全ステップが inconclusive(verify にアサーション0個等)= 実行はしたが何も検証していない。
    /// JUnit に inconclusive の概念が無いため isSkipped と対称に skipped として出す
    /// (record.passed は inconclusive だけでは false にならないので isSkipped とは別条件)
    static func isAllInconclusive(_ record: ScenarioRunRecord) -> Bool {
        record.passed && record.steps.total > 0
            && (record.steps.inconclusive ?? 0) == record.steps.total
    }

    private static func testcase(_ record: ScenarioRunRecord, className: String) -> String {
        let method = record.scenarioID.firstIndex(of: ".")
            .map { String(record.scenarioID[record.scenarioID.index(after: $0)...]) }
            ?? record.scenarioID
        let open = "    <testcase classname=\"\(escape(className))\" name=\"\(escape(method))\""
            + " time=\"\(seconds(record.durationMs))\""
        if record.passed {
            if isAllInconclusive(record) {
                let reason = record.timeline?.first { $0.status == "inconclusive" }?.description
                    ?? "inconclusive"
                return open + ">\n      <skipped message=\"\(escape(reason))\"/>\n    </testcase>"
            }
            return open + "/>"
        }

        if isSkipped(record) {
            let reason = record.failedSteps?.first?.description ?? "skipped"
            return open + ">\n      <skipped message=\"\(escape(reason))\"/>\n    </testcase>"
        }

        // message = 最初の失敗ステップの1行要約。本文 = 失敗ステップ詳細 + エラーログ +
        // レポートパス(調査の入口。CI の artifact に reports/ を上げる想定)
        let first = record.failedSteps?.first
        var message = first.map { step in
            step.description + (step.detail.map { " — \($0)" } ?? "")
        } ?? "failed"
        if record.timedOut == true { message = "timed out — " + message }

        var body: [String] = []
        for step in record.failedSteps ?? [] {
            var line = "step \(step.index): \(step.description)"
            if let detail = step.detail { line += "\n  \(detail)" }
            if let file = step.file, let lineNo = step.line { line += "\n  at \(file):\(lineNo)" }
            body.append(line)
        }
        if let logs = record.errorLogs, !logs.isEmpty {
            body.append("error logs:\n" + logs.joined(separator: "\n"))
        }
        if let report = record.reportPath { body.append("report: \(report)") }
        if let worker = record.worker { body.append("worker: \(worker)") }

        return open + ">\n      <failure message=\"\(escape(message))\">"
            + escape(body.joined(separator: "\n\n"))
            + "</failure>\n    </testcase>"
    }

    private struct Counts {
        var tests = 0
        var failures = 0
        var skipped = 0
        var totalMs = 0

        init() {}
        init(records: [ScenarioRunRecord]) {
            for record in records {
                tests += 1
                totalMs += record.durationMs
                if record.passed {
                    if JUnitReportWriter.isAllInconclusive(record) { skipped += 1 }
                    continue
                }
                if JUnitReportWriter.isSkipped(record) { skipped += 1 } else { failures += 1 }
            }
        }
        mutating func add(_ other: Counts) {
            tests += other.tests
            failures += other.failures
            skipped += other.skipped
            totalMs += other.totalMs
        }
    }

    private static func seconds(_ ms: Int) -> String {
        String(format: "%.3f", Double(ms) / 1000)
    }

    /// 属性値・本文の両方に使える保守的なエスケープ(' は属性を " で囲むため不要だが、
    /// 予約5文字すべてを変換して文脈を考えずに済ませる)
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}
