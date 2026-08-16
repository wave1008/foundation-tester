// XCTest の a11y サーバが一時的に落ちたとき(`kAXErrorAPIDisabled`)の扱いを固定する。
//
// **19件すべて同時刻クラスタ**(2026-08-04 00:55:29〜34 に6件・2026-08-01 に7件)で、
// 全レーンに一斉に出る = 環境要因。数秒で復旧するので、読み取りは待って撃ち直す。
// **書き込みは撃ち直さない**: 「撃つ前に落ちた」と断定できず、二重実行を作る方が高くつく
// (DriverError.isDefiniteDeliveryFailure と同じ判断)。

import XCTest
import FTCore
@testable import FTBridgeClient

private final class FlakyAccessibilityDriver: AppDriver, @unchecked Sendable {
    /// この回数だけ kAXErrorAPIDisabled を投げてから成功する
    var failuresBeforeSuccess: Int
    private(set) var snapshotAttempts = 0
    private(set) var tapAttempts = 0

    init(failuresBeforeSuccess: Int) { self.failuresBeforeSuccess = failuresBeforeSuccess }

    private static let outage = DriverError.badResponse(
        status: 500,
        body: #"Error Domain=com.apple.dt.xctest.automation-support.error Code=8 "Error getting main window kAXErrorAPIDisabled""#)

    func snapshot() async throws -> SnapshotResponse {
        snapshotAttempts += 1
        if snapshotAttempts <= failuresBeforeSuccess { throw Self.outage }
        return SnapshotResponse(sessionBundleID: "app",
                                screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                                elements: [], truncatedCount: 0)
    }

    func tap(x: Double, y: Double) async throws {
        tapAttempts += 1
        if tapAttempts <= failuresBeforeSuccess { throw Self.outage }
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "d", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func launch(bundleID: String) async throws {}
    func tap(ref: Int) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class AccessibilityOutageRetryTests: XCTestCase {

    func testClassifiesTheOutageOnlyForItsOwnSignature() {
        let outage = DriverError.badResponse(status: 500, body: "… kAXErrorAPIDisabled …")
        let otherServerError = DriverError.badResponse(status: 500, body: "boom")
        let sessionLost = DriverError.badResponse(status: 409, body: "kAXErrorAPIDisabled")

        XCTAssertTrue(SessionRecoveryDriver.isAccessibilityTemporarilyDown(outage))
        XCTAssertFalse(SessionRecoveryDriver.isAccessibilityTemporarilyDown(otherServerError),
                       "500 なら何でも待つ、にしてはいけない(本物の失敗を遅らせるだけ)")
        XCTAssertFalse(SessionRecoveryDriver.isAccessibilityTemporarilyDown(sessionLost),
                       "409 はセッション消失の経路(回復方法が違う)")
    }

    /// 読み取りは待って撃ち直す(復旧は数秒)
    func testSnapshotRetriesThroughATransientOutage() async throws {
        let base = FlakyAccessibilityDriver(failuresBeforeSuccess: 1)
        let driver = SessionRecoveryDriver(base: base)

        _ = try await driver.snapshot()

        XCTAssertEqual(base.snapshotAttempts, 2, "1回失敗したら撃ち直すこと")
        XCTAssertEqual(driver.lastActionNote?.contains("kAXErrorAPIDisabled"), true,
                       "黙って遅くならないよう注記を残すこと: \(driver.lastActionNote ?? "nil")")
    }

    /// **書き込みは撃ち直さない**(二重実行を作らない)
    func testWritesDoNotRetryThroughTheOutage() async {
        let base = FlakyAccessibilityDriver(failuresBeforeSuccess: 1)
        let driver = SessionRecoveryDriver(base: base)

        do {
            try await driver.tap(x: 1, y: 2)
            XCTFail("書き込みはそのまま失敗させるはず")
        } catch {}
        XCTAssertEqual(base.tapAttempts, 1, "撃ち直してはいけない")
    }
}
