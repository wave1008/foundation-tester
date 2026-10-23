// `bridge down --port` が inapp モードの片割れ(XCUITest ランナー)を残したときの知らせ。
// 残ったランナーは Simulator を止めた直後に起こし直す(Bridge.Down.remainingRunnerNotice の doc)。

import XCTest
@testable import fleetest

final class BridgeDownRemainingRunnerNoticeTests: XCTestCase {

    func testNamesTheRunnerLeftOnTheSameDevice() throws {
        let notice = try XCTUnwrap(Bridge.Down.remainingRunnerNotice(stopped: 8125, runnerPorts: [8126]))
        XCTAssertTrue(notice.contains("port: 8126"), notice)
        XCTAssertTrue(notice.contains("fleetest bridge down --port 8126"), notice)
        XCTAssertTrue(notice.contains("fleetest devices down"), notice)
        XCTAssertFalse(notice.contains("8125"), "止めたポートを残りとして挙げない: \(notice)")
    }

    func testSilentWhenTheStoppedPortWasTheOnlyRunner() {
        XCTAssertNil(Bridge.Down.remainingRunnerNotice(stopped: 8124, runnerPorts: [8124]))
        XCTAssertNil(Bridge.Down.remainingRunnerNotice(stopped: 8124, runnerPorts: []))
    }

    func testListsEveryRemainingRunner() throws {
        let notice = try XCTUnwrap(Bridge.Down.remainingRunnerNotice(stopped: 8123, runnerPorts: [8124, 8130]))
        XCTAssertTrue(notice.contains("port: 8124, 8130"), notice)
        XCTAssertTrue(notice.contains("fleetest bridge down --port 8124 / fleetest bridge down --port 8130"), notice)
    }
}
