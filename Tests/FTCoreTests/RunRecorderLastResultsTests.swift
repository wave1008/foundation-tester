// `fleetest run --failed` の「直近失敗」に、始まらなかったシナリオ(noWorker / interrupted)を
// 含め、意図された対象外(notApplicable)を含めない規則の固定。
// 置き場は引数で注入した一時フォルダだけ(実リポジトリの .fleetest/last-results を触らない)。

import XCTest
@testable import FTCore

final class RunRecorderLastResultsTests: XCTestCase {

    private var root: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-lastresults-recorder-\(UUID().uuidString)")
        stateDir = root.appendingPathComponent("last-results")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRecorder(lastResultsDir: URL?) -> RunRecorder {
        RunRecorder.begin(project: TestProject(name: "P", rootURL: root), profile: "ios", trigger: "test",
                          captureHostMetrics: false, lastResultsDir: lastResultsDir)
    }

    /// 規則の本体: 事故は失敗に数え、意図された対象外は数えない
    func testSkipKindRuleCountsAccidentsButNotNotApplicable() {
        XCTAssertTrue(ScenarioSkipKind.noWorker.countsAsFailedLastTime)
        XCTAssertTrue(ScenarioSkipKind.interrupted.countsAsFailedLastTime)
        XCTAssertFalse(ScenarioSkipKind.notApplicable.countsAsFailedLastTime)
    }

    func testRecordSkippedNoWorkerAndInterruptedAreFailedLastTime() {
        let recorder = makeRecorder(lastResultsDir: stateDir)
        recorder.recordSkipped(scenarioID: "A.one", title: nil, platform: "ios", worker: nil,
                               reason: "no worker available (platform: ios)")
        recorder.recordSkipped(scenarioID: "B.two", title: nil, platform: "ios", worker: nil,
                               reason: RunRecorder.interruptedBeforeStartReason, kind: .interrupted)
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), ["A.one", "B.two"])
    }

    func testRecordSkippedNotApplicableIsNotFailedLastTime() {
        let recorder = makeRecorder(lastResultsDir: stateDir)
        recorder.recordSkipped(scenarioID: "C.three", title: nil, platform: "android", worker: nil,
                               reason: "declared for another platform", kind: .notApplicable)
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), [])
        XCTAssertEqual(LastResultsStore.recordedCount(stateDir: stateDir), 0, "対象外は記録自体を作らない")
    }

    /// 始まらなかったシナリオは、前回緑だった記録を失敗で上書きする(後勝ち)
    func testSkippedOverwritesAnEarlierPass() {
        LastResultsStore.record(stateDir: stateDir, scenarioID: "A.one", passed: true)
        let recorder = makeRecorder(lastResultsDir: stateDir)
        recorder.recordSkipped(scenarioID: "A.one", title: nil, platform: "ios", worker: nil, reason: "x")
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), ["A.one"])
    }

    func testRecordInterruptedBeforeStartWritesFailures() {
        let recorder = makeRecorder(lastResultsDir: stateDir)
        let infos = [ScenarioInfo(id: "D.four", title: "t", platform: nil)]
        recorder.recordInterruptedBeforeStart(infos, defaultPlatform: "ios")
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), ["D.four"])
    }

    /// 供給段の例外で始まらなかった分(`recordLastResultsFailed`)
    func testRecordLastResultsFailedMarksEveryGivenScenario() {
        let recorder = makeRecorder(lastResultsDir: stateDir)
        recorder.recordLastResultsFailed(["E.five", "F.six"])
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), ["E.five", "F.six"])
    }

    /// 置き場を渡さない recorder(テスト・既定)は何も書かない
    func testNoLastResultsDirWritesNothing() {
        let recorder = makeRecorder(lastResultsDir: nil)
        recorder.recordSkipped(scenarioID: "A.one", title: nil, platform: "ios", worker: nil, reason: "x")
        recorder.recordLastResultsFailed(["B.two"])
        XCTAssertEqual(LastResultsStore.recordedCount(stateDir: stateDir), 0)
    }

    func testNothingFailedMessageSeparatesNeverRunFromAllPassed() {
        XCTAssertTrue(LastResultsStore.nothingFailedMessage(recordedCount: 0, failedCount: 0).contains("nothing has run"))
        XCTAssertTrue(LastResultsStore.nothingFailedMessage(recordedCount: 3, failedCount: 0)
            .contains("every recorded scenario passed"))
        // 直近失敗が選んだ範囲の外にだけある: 「全部緑」と言わない
        let outside = LastResultsStore.nothingFailedMessage(recordedCount: 3, failedCount: 2)
        XCTAssertFalse(outside.contains("every recorded scenario passed"), outside)
        XCTAssertTrue(outside.contains("2 scenario(s) outside this selection"), outside)
        LastResultsStore.record(stateDir: stateDir, scenarioID: "A.one", passed: true)
        XCTAssertEqual(LastResultsStore.recordedCount(stateDir: stateDir), 1)
    }
}
