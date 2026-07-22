// SessionRecoveryDriver の契約を検証する:
// - ref を使わない操作は 409 → activate → 再試行(1回だけ)
// - ref を使う操作は 409 → activate はするが再試行しない(refFrames クリアで別要素を操作しかねないため)
// - launch 前(lastBundleID なし)は回復せずそのまま再スロー
// - 再試行後も 409 なら無限ループせずそのまま再スロー

import XCTest
@testable import FTBridgeClient
import FTCore

private final class FakeAppDriver: AppDriver {
    private(set) var activateCalls: [String] = []
    private(set) var snapshotCallCount = 0
    private(set) var tapRefCallCount = 0

    /// 呼び出し順ごとの成否(true=409 を throw)。尽きたら最後の値を繰り返す
    var snapshotShouldFail: [Bool] = []
    var tapRefShouldFail: [Bool] = []

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func launch(bundleID: String) async throws {}
    func activate(bundleID: String) async throws { activateCalls.append(bundleID) }
    func openAppSwitcher() async throws {}
    func home() async throws {}

    private static let sessionLost = DriverError.badResponse(status: 409, body: "セッションがありません")

    func snapshot() async throws -> SnapshotResponse {
        defer { snapshotCallCount += 1 }
        if shouldFail(snapshotShouldFail, callCount: snapshotCallCount) { throw Self.sessionLost }
        return SnapshotResponse(sessionBundleID: nil,
                                screen: FTRect(x: 0, y: 0, width: 100, height: 100),
                                elements: [], truncatedCount: 0)
    }

    func tap(ref: Int) async throws {
        defer { tapRefCallCount += 1 }
        if shouldFail(tapRefShouldFail, callCount: tapRefCallCount) { throw Self.sessionLost }
    }

    private func shouldFail(_ schedule: [Bool], callCount: Int) -> Bool {
        guard !schedule.isEmpty else { return false }
        return schedule[min(callCount, schedule.count - 1)]
    }

    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
             pressSeconds: Double, durationSeconds: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func press(x: Double, y: Double, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

final class SessionRecoveryDriverTests: XCTestCase {
    func testSnapshotRecoversAfterSingle409() async throws {
        let fake = FakeAppDriver()
        fake.snapshotShouldFail = [true, false]
        let driver = SessionRecoveryDriver(base: fake)
        try await driver.launch(bundleID: "com.example.app")

        _ = try await driver.snapshot()

        XCTAssertEqual(fake.activateCalls, ["com.example.app"])
        XCTAssertEqual(fake.snapshotCallCount, 2)
    }

    func testTapRefDoesNotRetryButRecoversSessionAndRethrows() async throws {
        let fake = FakeAppDriver()
        fake.tapRefShouldFail = [true]
        let driver = SessionRecoveryDriver(base: fake)
        try await driver.launch(bundleID: "com.example.app")

        do {
            try await driver.tap(ref: 1)
            XCTFail("409 を再スローするはず")
        } catch let DriverError.badResponse(status, _) {
            XCTAssertEqual(status, 409)
        }

        XCTAssertEqual(fake.activateCalls, ["com.example.app"],
                       "ref 操作でも次ステップ復帰のためセッションは張り直す")
        XCTAssertEqual(fake.tapRefCallCount, 1, "ref 操作は再試行しない")
    }

    func testNoRecoveryBeforeLaunch() async throws {
        let fake = FakeAppDriver()
        fake.snapshotShouldFail = [true]
        let driver = SessionRecoveryDriver(base: fake)

        do {
            _ = try await driver.snapshot()
            XCTFail("409 を再スローするはず")
        } catch let DriverError.badResponse(status, _) {
            XCTAssertEqual(status, 409)
        }

        XCTAssertTrue(fake.activateCalls.isEmpty, "launch 前は回復対象の bundleID が無い")
        XCTAssertEqual(fake.snapshotCallCount, 1, "再試行しない")
    }

    func testRetryAlsoFailingDoesNotLoop() async throws {
        let fake = FakeAppDriver()
        fake.snapshotShouldFail = [true, true]
        let driver = SessionRecoveryDriver(base: fake)
        try await driver.launch(bundleID: "com.example.app")

        do {
            _ = try await driver.snapshot()
            XCTFail("再試行後も 409 ならそのまま再スローするはず")
        } catch let DriverError.badResponse(status, _) {
            XCTAssertEqual(status, 409)
        }

        XCTAssertEqual(fake.activateCalls, ["com.example.app"], "回復の発火は1回だけ")
        XCTAssertEqual(fake.snapshotCallCount, 2, "初回+再試行の2回で打ち切り")
    }
}
