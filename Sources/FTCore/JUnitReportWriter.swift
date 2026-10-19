// JUnitReportWriter.swift
// run の結果(ScenarioRunRecord)→ JUnit XML。CI(GitHub Actions / Jenkins 等)のテストレポート
// 取り込み用で、`fleetest run --junit <path>` が run 終了時に書き出す。
// 3つの実行経路(逐次 / --port 並列 / --profile 並列)すべてが RunRecorder 経由で
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

    /// 供給段(ワーカー構築・install 等)で run が1本も始まらずに落ちたときの JUnit。
    /// `unstarted` のうち記録の無いシナリオを `<failure>`(理由 = abortReason)として足す。
    /// **記録は書かない**(結果 DB には run.json の abortReason だけが残る = 集計を変えない)。
    /// 足す形は `.noWorker` の合成レコード = `isSkipped` が `<failure>` に倒す形と対
    public static func xml(project: String, records: [ScenarioRunRecord],
                           unstarted: [(id: String, title: String?, platform: String)],
                           abortReason: String) -> String {
        let recorded = Set(records.map(\.scenarioID))
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let synthetic = unstarted.filter { !recorded.contains($0.id) }.map {
            ScenarioRunRecord(
                scenarioID: $0.id, title: $0.title, platform: $0.platform, passed: false,
                startedAt: startedAt, durationMs: 0, steps: StepCountsRecord(total: 1, skipped: 1),
                failedSteps: [FailedStepRecord(
                    index: 0, description: "the run aborted before this scenario started: " + abortReason)],
                skipKind: .noWorker)
        }
        return xml(project: project, records: records + synthetic)
    }

    /// シナリオ一覧が得られる前(シナリオのビルド・一覧の取得)に run が落ちたときの JUnit。
    /// シナリオ単位の `<testcase>` は作れないので、段階(`phase` = "build" 等)を1つの `<failure>` にする。
    /// 書かないと、CI でいちばん多い失敗(シナリオのコンパイルエラー)で取り込みが「レポートが無い」で止まる
    public static func xml(project: String, failedPhase phase: String, reason: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites name="\(escape(project))" tests="1" failures="1" errors="0" skipped="0" time="0.000">
          <testsuite name="fleetest" tests="1" failures="1" errors="0" skipped="0" time="0.000">
            <testcase classname="fleetest" name="\(escape(phase))" time="0.000">
              <failure message="\(escape("the run failed at the \(phase) step, before any scenario started"))">\
        \(escape(reason))</failure>
            </testcase>
          </testsuite>
        </testsuites>
        """ + "\n"
    }

    /// scenarioID の最初の "." より前(クラス名)。"." が無ければ全体
    static func className(of scenarioID: String) -> String {
        scenarioID.firstIndex(of: ".").map { String(scenarioID[..<$0]) } ?? scenarioID
    }

    /// recordSkipped が書く形(全ステップ skipped・failed 0・不合格)= 実行に至らなかったシナリオ。
    /// 途中まで走って中断したシナリオは skipped>0 でも failed>0 なので failure 扱いになる。
    /// **`skipKind == .noWorker`(ワーカー不在・全滅などの事故)は `<failure>` に出す** —— 意図された
    /// 未実行(`notApplicable`)と同じ顔にすると、JUnit の failures だけを見る CI が「緑で 1 本も
    /// 走っていない」run を通す(exit code は 1 でも Jenkins の JUnit 集計は failures を見る)
    /// **`.interrupted`(中断で始まらなかった)も `<failure>`** —— run.json と exit code は失敗に数えるので、JUnit だけ
    /// skipped にすると、CI の中断で failures=0 の緑に見える。`<skipped>` は意図された未実行(`notApplicable`)と旧形式だけ
    static func isSkipped(_ record: ScenarioRunRecord) -> Bool {
        record.skipKind != .noWorker && record.skipKind != .interrupted
            && !record.passed && record.steps.failed == 0
            && record.steps.total > 0 && record.steps.skipped == record.steps.total
    }

    /// 全ステップが inconclusive(verify にアサーション0個等)= 実行はしたが何も検証していない。
    /// JUnit に inconclusive の概念が無いため isSkipped と対称に skipped として出す
    /// (record.passed は inconclusive だけでは false にならないので isSkipped とは別条件)
    /// 子が「この環境では成り立たない」と宣言したシナリオ(`skipKind: notApplicable` + passed == true)。
    /// 合成レコード(passed == false)は isSkipped 側
    static func isDeclaredNotApplicable(_ record: ScenarioRunRecord) -> Bool {
        record.passed && record.skipKind == .notApplicable
    }

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
            if isDeclaredNotApplicable(record) {
                return open + ">\n      <skipped message=\"\(escape(record.skipReason ?? "not applicable"))\"/>\n    </testcase>"
            }
            if isAllInconclusive(record) {
                let reason = record.timeline?.first { $0.status == "inconclusive" }?.description
                    ?? "inconclusive"
                return open + ">\n      <skipped message=\"\(escape(reason))\"/>\n    </testcase>"
            }
            // **自己修復で通った回は印を残す**(合否は変えない)。素の `<testcase/>` にすると、CI は
            // 「緑だがセレクタは壊れている」を1件も見られない。JUnit に警告の語彙は無いので `<system-out>`
            if let healedNote = HealedScenarios.note(for: record) {
                return open + ">\n      <system-out>\(escape(healedNote))</system-out>\n    </testcase>"
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
                    if JUnitReportWriter.isDeclaredNotApplicable(record)
                        || JUnitReportWriter.isAllInconclusive(record) { skipped += 1 }
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
            guard Self.isValidXMLCharacter(ch) else { continue }
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

    /// XML 1.0 の Char 生成規則(`#x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] |
    /// [#x10000-#x10FFFF]`)に無い文字を落とす。adb/ドライバ出力に混じる制御文字(ESC・NUL 等)は
    /// この範囲外で、混じると XML が not well-formed になり `JUnitMerge` がホストのファイルを
    /// 丸ごと読み飛ばす(5文字だけのエスケープでは防げない)
    static func isValidXMLCharacter(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return true
            default: return false
            }
        }
    }
}
