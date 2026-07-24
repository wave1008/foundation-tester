// VideoRecordingCoordinator の純粋な判定ロジック(recordFailuresOnly の区間スキップ)を検証する。
// セッション(simctl/adb)を要する finalize 本体はここでは対象にしない。

import XCTest
@testable import FTCore

final class VideoRecordingCoordinatorTests: XCTestCase {

    func testShouldSkipWhenFailuresOnlyAndPassed() {
        XCTAssertTrue(VideoRecordingCoordinator.shouldSkip(failuresOnly: true, passed: true),
                      "recordFailuresOnly かつ確実に成功したシナリオはスキップするはず")
    }

    func testShouldNotSkipWhenFailuresOnlyAndFailed() {
        XCTAssertFalse(VideoRecordingCoordinator.shouldSkip(failuresOnly: true, passed: false))
    }

    func testShouldNotSkipWhenFailuresOnlyAndUnknown() {
        XCTAssertFalse(VideoRecordingCoordinator.shouldSkip(failuresOnly: true, passed: nil),
                      "判定不能(scenarioFinished 未着等)は安全側に倒して保存対象に残すはず")
    }

    func testShouldNotSkipWhenFailuresOnlyDisabled() {
        XCTAssertFalse(VideoRecordingCoordinator.shouldSkip(failuresOnly: false, passed: true),
                      "recordFailuresOnly が無効なら成功シナリオも保存するはず")
        XCTAssertFalse(VideoRecordingCoordinator.shouldSkip(failuresOnly: false, passed: false))
        XCTAssertFalse(VideoRecordingCoordinator.shouldSkip(failuresOnly: false, passed: nil))
    }
}
