// `launchApp(url:)` の配送前の待ち(LaunchURLReadiness / StepExecutor.awaitInteractiveUI)。
// witness: E2E-RN ios-inapp の `ディープリンクで意図した画面に遷移すること.S0010` が M1Max で「ホーム」のまま
// (JS が listener を登録する前に simctl openurl が届いて捨てられた)。期待値はリテラル。

import XCTest
@testable import FTCore

final class LaunchURLReadinessTests: XCTestCase {
    private func element(_ ref: Int, _ type: String, id: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: Double(ref * 20), width: 100, height: 20), depth: 1)
    }

    /// 起動画面(ラベルと other だけ)は「まだ」、ボタン・入力欄が 1 つでも載れば「描かれた」
    func testLaunchScreenIsNotReadyButAButtonOrFieldIs() {
        XCTAssertFalse(LaunchURLReadiness.hasInteractiveElement([]))
        XCTAssertFalse(LaunchURLReadiness.hasInteractiveElement([element(1, "other"), element(2, "staticText")]))
        XCTAssertTrue(LaunchURLReadiness.hasInteractiveElement([element(1, "staticText"), element(2, "button")]))
        XCTAssertTrue(LaunchURLReadiness.hasInteractiveElement([element(1, "textField")]))
        XCTAssertTrue(LaunchURLReadiness.hasInteractiveElement([element(1, "cell")]))
    }

    /// 実経路: 起動画面 → 起動画面 → ホーム(ボタン)の順に木が変わる欄で、ホームが載るまで撮り続ける
    func testWaitsUntilATappableElementAppears() async throws {
        let launchScreen = [element(1, "staticText")]
        let home = [element(1, "staticText"), element(2, "button", id: "nav_selector")]
        let driver = SnapshotSequenceDriver(trees: [launchScreen, launchScreen, home])
        let ready = try await StepExecutor(driver: driver, isAndroid: false).awaitInteractiveUI(timeoutMs: 10_000)
        XCTAssertTrue(ready)
        XCTAssertEqual(driver.snapshotCount, 3, "ホームが載った 3 枚目で返る")
    }

    /// 触れる要素が最後まで載らなければ false(呼び手は配送したうえで注記を残す)。予算は所要で測る
    func testGivesUpAfterTheBudgetWhenNothingTappableAppears() async throws {
        let driver = SnapshotSequenceDriver(trees: [[element(1, "staticText")]])
        let started = Date()
        let ready = try await StepExecutor(driver: driver, isAndroid: false).awaitInteractiveUI(timeoutMs: 300)
        XCTAssertFalse(ready)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.3)
        XCTAssertLessThan(elapsed, 3, "予算(0.3 秒)を大きく超えて待ってはいけない: \(elapsed)s")
        XCTAssertGreaterThanOrEqual(driver.snapshotCount, 2)
    }
}

/// snapshot のたびに次の木へ進む(尽きたら最後を繰り返す)
private final class SnapshotSequenceDriver: AppDriver {
    private let trees: [[ElementInfo]]
    private(set) var snapshotCount = 0
    init(trees: [[ElementInfo]]) { self.trees = trees }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { false }
    func foregroundAppID() async throws -> String? { nil }
    func launch(bundleID: String) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        let tree = trees[min(snapshotCount, trees.count - 1)]
        snapshotCount += 1
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                elements: tree, truncatedCount: 0)
    }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}
