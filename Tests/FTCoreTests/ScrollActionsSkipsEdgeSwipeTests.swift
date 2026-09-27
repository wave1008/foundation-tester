// executeDirectScrollToEdge の配線: Android が ElementInfo.scrollActions を申告する容器では、
// もう動かせない向きだと分かった時点で swipe を1本も送らずに端と確定する(PullToRefreshBox の
// 先頭で確認の1本を送ると引っ張り更新が余分に走る実害の陽性対照。90_既知の制約.swift S0020)。
// scrollActions が両方の向きを持つとき(端ではない)は、これまでどおり署名の不変化で確定する
// (= 少なくとも1本は送る)。フェイクドライバの形は EdgeSignatureTests.FlickeringTopDriver に揃える。

import XCTest
@testable import FTCore

final class ScrollActionsSkipsEdgeSwipeTests: XCTestCase {

    /// scrollToTop(finger "down")。容器が forward/down しか申告しない = もう上へは動けない
    func testScrollToTopSendsNoSwipesWhenScrollActionsAlreadyAtTop() async throws {
        let driver = ScrollActionsDriver(scrollActions: ["forward", "down"])
        let outcome = await StepExecutor(driver: driver, isAndroid: true)
            .execute(FlowStep(action: "scrollToEdge", direction: "down", maxSwipes: 20))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.swipes, 0, "端と分かっている容器へ確認の swipe を送ってしまった")
    }

    /// 同じ容器が両方向を申告するとき(まだ端ではない)は、これまでどおり実際に撃って確かめる
    func testScrollToTopStillSwipesWhenScrollActionsAllowFurtherMovement() async throws {
        let driver = ScrollActionsDriver(scrollActions: ["backward", "forward"])
        let outcome = await StepExecutor(driver: driver, isAndroid: true)
            .execute(FlowStep(action: "scrollToEdge", direction: "down", maxSwipes: 20))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertGreaterThan(driver.swipes, 0, "端ではない容器なのに1本も送らずに終わった")
    }

    /// iOS 相当(scrollActions を申告しない)は今までどおり: 署名の不変化だけで確定するので撃つ
    func testScrollToTopStillSwipesWhenScrollActionsUnknown() async throws {
        let driver = ScrollActionsDriver(scrollActions: nil)
        let outcome = await StepExecutor(driver: driver, isAndroid: false)
            .execute(FlowStep(action: "scrollToEdge", direction: "down", maxSwipes: 20))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertGreaterThan(driver.swipes, 0, "scrollActions 未申告なのに撃たずに終わった(iOS の挙動が変わった)")
    }
}

/// 常に同じ木(先頭に scrollable な容器が1つだけ)を返すフェイク。`scrollActions` だけを差し替えて
/// 端判定の分岐を切り替える。中身が本当に動くかは関知しない(署名は最初から不変 = 送る前から端の形)
private final class ScrollActionsDriver: AppDriver {
    private let scrollActions: [String]?
    private(set) var swipes = 0

    init(scrollActions: [String]?) {
        self.scrollActions = scrollActions
    }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws {}
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { swipes += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swipes += 1
    }
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
            elements: [
                ElementInfo(ref: 1, type: "other", identifier: "list", label: nil, value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: 0, width: 400, height: 800), depth: 1,
                            scrollable: true, scrollActions: scrollActions),
            ],
            truncatedCount: 0)
    }
}
