// フリート実行の JUnit 集約(`fleetest run --fleet --junit`)。各エントリの --junit 出力を
// 結合する純粋ロジックを、期待値の完全一致で固める。実 I/O(一時ファイルの読み書き・
// 子プロセスへの --junit 中継)は Sources/fleetest/FleetRunner.swift 側で、ここは対象外。

import XCTest
@testable import FTCore

final class JUnitMergeTests: XCTestCase {

    private func record(id: String, passed: Bool, durationMs: Int = 1000,
                        steps: StepCountsRecord = StepCountsRecord(total: 1, passed: 1),
                        failedSteps: [FailedStepRecord]? = nil) -> ScenarioRunRecord {
        ScenarioRunRecord(runID: "r1", scenarioID: id, platform: "ios", worker: nil,
                          passed: passed, timedOut: nil,
                          startedAt: "2026-08-16T00:00:00Z", durationMs: durationMs,
                          steps: steps, reportPath: nil,
                          failedSteps: failedSteps, errorLogs: nil, timeline: nil)
    }

    // MARK: - hostname の付与・属性の保持

    func testEachTestsuiteGetsItsEntrysHostnameAndKeepsExistingAttributes() throws {
        let hostAXML = JUnitReportWriter.xml(project: "E2E", records: [
            record(id: "Login.S1", passed: true, durationMs: 1000),
        ])
        let hostBXML = JUnitReportWriter.xml(project: "E2E", records: [
            record(id: "Login.S2", passed: false, durationMs: 500,
                   steps: StepCountsRecord(total: 1, failed: 1),
                   failedSteps: [FailedStepRecord(index: 1, description: "tap \"x\"")]),
        ])

        let merged = JUnitMerge.merge([
            JUnitMerge.Entry(host: "m1ultra", xml: hostAXML),
            JUnitMerge.Entry(host: "m1max", xml: hostBXML),
        ], project: "E2E")

        // 同じ testsuite 名("Login")が2ホスト分そのまま残り、hostname だけ足された形になる。
        // 既存属性(name/tests/failures/errors/skipped/time)の値・並びは変えない
        XCTAssertTrue(merged.contains(
            #"<testsuite name="Login" tests="1" failures="0" errors="0" skipped="0" time="1.000" hostname="m1ultra">"#),
            merged)
        XCTAssertTrue(merged.contains(
            #"<testsuite name="Login" tests="1" failures="1" errors="0" skipped="0" time="0.500" hostname="m1max">"#),
            merged)
        // testcase/failure の中身も素通しされる
        XCTAssertTrue(merged.contains(#"<testcase classname="Login" name="S1" time="1.000"/>"#), merged)
        XCTAssertTrue(merged.contains(#"<failure message="tap &quot;x&quot;">"#), merged)
    }

    // MARK: - 合計は結合後に数え直す(エントリ自身の外側合計は信用しない)

    func testGrandTotalsAreRecountedFromIncludedTestsuitesNotFromTheEntrysOwnOuterTotal() throws {
        // hostA の外側 <testsuites> は嘘の合計(tests="999")を書いているが、
        // 中の <testsuite> 自身の属性(信用する側)は正しい
        let hostAXML = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites name="E2E" tests="999" failures="999" errors="0" skipped="999" time="999.000">
          <testsuite name="A" tests="1" failures="0" errors="0" skipped="0" time="1.500">
            <testcase classname="A" name="x" time="1.500"/>
          </testsuite>
        </testsuites>
        """#
        let hostBXML = JUnitReportWriter.xml(project: "E2E", records: [
            record(id: "B.y", passed: false, durationMs: 250,
                   steps: StepCountsRecord(total: 1, failed: 1),
                   failedSteps: [FailedStepRecord(index: 1, description: "f")]),
        ])

        let merged = JUnitMerge.merge([
            JUnitMerge.Entry(host: "hostA", xml: hostAXML),
            JUnitMerge.Entry(host: "hostB", xml: hostBXML),
        ], project: "E2E")

        XCTAssertTrue(merged.contains(
            #"<testsuites name="E2E" tests="2" failures="1" errors="0" skipped="0" time="1.750">"#), merged)
    }

    // MARK: - 出力が無いエントリ = 合成した失敗を1件

    func testMissingOutputBecomesASyntheticFailureNotASilentPass() throws {
        let merged = JUnitMerge.merge([
            JUnitMerge.Entry(host: "m1max", xml: nil),
        ], project: "E2E")

        XCTAssertEqual(merged, #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites name="E2E" tests="1" failures="1" errors="0" skipped="0" time="0.000">
          <testsuite name="fleet-entry-missing" tests="1" failures="1" errors="0" skipped="0" time="0.000" hostname="m1max">
            <testcase classname="fleet-entry-missing" name="m1max" time="0.000">
              <failure message="entry &quot;m1max&quot; produced no JUnit report">entry &quot;m1max&quot; produced no JUnit report</failure>
            </testcase>
          </testsuite>
        </testsuites>

        """#)
    }

    /// 空文字も「出力が無い」と同じ扱い(--junit が0バイトを書いた・ファイルが存在しない、
    /// どちらも結果は区別しない)
    func testEmptyStringXMLIsTreatedTheSameAsMissing() throws {
        let merged = JUnitMerge.merge([JUnitMerge.Entry(host: "h", xml: "")], project: "P")
        XCTAssertTrue(merged.contains(#"name="fleet-entry-missing""#), merged)
        XCTAssertTrue(merged.contains(#"tests="1" failures="1""#), merged)
    }

    /// 実際に0件のシナリオを実行して妥当な空 <testsuites> を書いたエントリは、
    /// 「出力が無い」とは別物 —— missing マーカーを合成しない
    func testEntryThatLegitimatelyRanZeroScenariosIsNotTreatedAsMissing() throws {
        let emptyXML = JUnitReportWriter.xml(project: "E2E", records: [])
        let merged = JUnitMerge.merge([JUnitMerge.Entry(host: "h", xml: emptyXML)], project: "E2E")
        XCTAssertFalse(merged.contains("fleet-entry-missing"), merged)
        XCTAssertTrue(merged.contains(#"tests="0" failures="0" errors="0" skipped="0" time="0.000""#), merged)
    }

    // MARK: - 読めないエントリは**失敗として結合結果に残す**(throw して1件も書かない、はしない)

    /// 壊れた XML でも throw しない。**結合結果に赤いテストとして残す** ——
    /// 1件も書かないと CI からは「JUnit が無い」= 設定次第で緑にも見える
    func testMalformedXMLBecomesAFailingSuiteNamingTheHost() {
        let merged = JUnitMerge.merge([JUnitMerge.Entry(host: "m1max", xml: "<not-xml")], project: "P")
        XCTAssertTrue(merged.contains("fleet-entry-unreadable"), merged)
        XCTAssertTrue(merged.contains("m1max"), merged)
        XCTAssertTrue(merged.contains(#"tests="1" failures="1""#), merged)
    }

    func testUnexpectedRootElementBecomesAFailingSuite() {
        let merged = JUnitMerge.merge([JUnitMerge.Entry(host: "h", xml: "<somethingElse/>")], project: "P")
        XCTAssertTrue(merged.contains("fleet-entry-unreadable"), merged)
        XCTAssertTrue(merged.contains(#"failures="1""#), merged)
    }

    /// 属性が欠けた testsuite も同じ扱い。**合計を数え直せない入力を黙って混ぜない**
    func testTestsuiteMissingARequiredAttributeBecomesAFailingSuite() {
        let xml = #"""
        <testsuites name="P" tests="1" failures="0" errors="0" skipped="0" time="1.000">
          <testsuite name="A" failures="0" errors="0" skipped="0" time="1.000">
            <testcase classname="A" name="x" time="1.000"/>
          </testsuite>
        </testsuites>
        """#
        let merged = JUnitMerge.merge([JUnitMerge.Entry(host: "h", xml: xml)], project: "P")
        XCTAssertTrue(merged.contains("fleet-entry-unreadable"), merged)
        XCTAssertFalse(merged.contains(#"name="A""#), merged)
    }

    /// 1つが壊れていても**他のエントリの結果は失われない**(片方の事故で全部を捨てない)
    func testOtherEntriesSurviveAWreckedOne() {
        let good = JUnitReportWriter.xml(project: "P", records: [])
        let merged = JUnitMerge.merge([
            JUnitMerge.Entry(host: "broken", xml: "<not-xml"),
            JUnitMerge.Entry(host: "ok", xml: good),
        ], project: "P")
        XCTAssertTrue(merged.contains("fleet-entry-unreadable"), merged)
        XCTAssertTrue(merged.contains(#"hostname="ok""#) || merged.contains(#"tests="1" failures="1""#), merged)
    }
    // MARK: - エスケープ

    func testHostNameIsEscapedInHostnameAttributeAndInTheMissingMarker() throws {
        let merged = JUnitMerge.merge([JUnitMerge.Entry(host: #"m1<max>&"'"#, xml: nil)], project: "P")
        XCTAssertTrue(merged.contains(#"hostname="m1&lt;max&gt;&amp;&quot;&apos;""#), merged)
        XCTAssertFalse(merged.contains("m1<max>&\"'"), merged)
    }
}
