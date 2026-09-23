import XCTest
@testable import FTBridgeClient

/// 実機の UI 自動化の承認待ち(Touch ID の画面が出る区間)の判定。ログの形は
/// 2026-09-24 に iPhone SE3 で採ったもの(xcodebuild のテストログは CRLF)
final class AutomationApprovalTests: XCTestCase {
    private let header = "--- xcodebuild: WARNING: Using the first of multiple matching destinations:\r\n"
        + "{ platform:iOS, arch:arm64e, id:00008110-000260242EEB801E, name:iPhone SE3 }\r\n"
    private let runnerStarted = "2026-09-24 00:46:01.681249+0900 FleetestRunnerUITests-Runner[10741:4396638]"
        + " [Default] Running tests...\r\n"
    private let timedOut = "2026-09-24 00:47:01.737751+0900 FleetestRunnerUITests-Runner[10741:4396638]"
        + " [Default] Failed to initialize for UI testing: Error Domain=com.apple.dt.XCTest.XCTFuture"
        + " Code=1000 \"Timed out while enabling automation mode.\"\r\n"
    private let suiteStarted = "Test Suite 'All tests' started at 2026-09-24 00:46:05.001\r\n"

    func testNotPendingBeforeTheRunnerProcessStarts() {
        XCTAssertFalse(IOSDeviceTransport.awaitingAutomationApproval(inLog: header))
    }

    func testPendingWhileTheRunnerWaitsForAutomationMode() {
        XCTAssertTrue(IOSDeviceTransport.awaitingAutomationApproval(inLog: header + runnerStarted))
    }

    /// 承認されてテスト本体が始まったら待ちは終わり
    func testNotPendingOnceTheSuiteStarted() {
        XCTAssertFalse(IOSDeviceTransport.awaitingAutomationApproval(
            inLog: header + runnerStarted + suiteStarted))
    }

    /// 打ち切られたら待ちは終わり(失敗は runnerFailureReason が名指しする)
    func testNotPendingAfterTheTimeout() {
        XCTAssertFalse(IOSDeviceTransport.awaitingAutomationApproval(
            inLog: header + runnerStarted + timedOut))
    }

    /// 出入りは1回ずつ・待ちを抜ければ(失敗・中断でも)必ず閉じる
    func testTrackerReportsEachTransitionOnceAndClosesOnFinish() {
        var events: [Bool] = []
        var lines: [String] = []
        let tracker = AutomationApprovalTracker(notify: { events.append($0) }, log: { lines.append($0) })
        tracker.observe(log: header)
        tracker.observe(log: header + runnerStarted)
        tracker.observe(log: header + runnerStarted)
        XCTAssertEqual(events, [true])
        XCTAssertEqual(lines.count, 1, "\(lines)")
        // 上限で諦めるときの名指しはこれを見る(総称の「時間内に上がらなかった」にしない)
        XCTAssertTrue(tracker.pending)
        tracker.finish()
        XCTAssertFalse(tracker.pending)
        tracker.finish()
        XCTAssertEqual(events, [true, false])
    }

    func testTrackerClosesWhenTheSuiteStarts() {
        var events: [Bool] = []
        let tracker = AutomationApprovalTracker(notify: { events.append($0) }, log: { _ in })
        tracker.observe(log: header + runnerStarted)
        tracker.observe(log: header + runnerStarted + suiteStarted)
        tracker.finish()
        XCTAssertEqual(events, [true, false])
    }
}
