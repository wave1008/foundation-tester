import XCTest
@testable import FTCore

/// 操作ごとの画像整定の計画表(ユーザー承認の値)。期待値はリテラルで固定する
final class ImageSettlePlanTests: XCTestCase {
    private func p(_ fw: AppUIFramework?, android: Bool = false, _ kind: ImageSettleActionKind) -> ImageSettlePlan {
        ImageSettlePlan.plan(framework: fw, isAndroid: android, kind: kind)
    }

    private func expect(_ plan: ImageSettlePlan, quiet: Int, cap: Int, event: Bool = false, tree: Bool = false,
                        backoff: Int = 0, host: Bool, line: UInt = #line) {
        XCTAssertEqual(plan, ImageSettlePlan(quietMs: quiet, capMs: cap, waitEvent: event, armTree: tree,
                                             backoffMs: backoff, hostTreeSettle: host), line: line)
    }

    func testIOSUIKitBased() {
        for (fw, cap) in [(AppUIFramework.swiftUI, 3700), (.uikit, 3700), (.reactNative, 3000)] {
            expect(p(fw, .tap), quiet: 250, cap: cap, host: false)
            expect(p(fw, .text), quiet: 250, cap: cap, host: false)
            expect(p(fw, .scroll), quiet: 250, cap: cap, event: true, host: false)
        }
    }

    func testIOSSelfRendered() {
        for kind in [ImageSettleActionKind.tap, .text] {
            expect(p(.compose, kind), quiet: 250, cap: 4400, tree: true, host: true)
            expect(p(.flutter, kind), quiet: 250, cap: 3000, tree: true, host: true)
        }
        expect(p(.compose, .scroll), quiet: 450, cap: 4400, backoff: 150, host: true)
        expect(p(.flutter, .scroll), quiet: 250, cap: 3000, backoff: 150, host: true)
    }

    func testIOSUnknownTreatedLikeCompose() {
        for fw in [nil, AppUIFramework.androidView] {
            expect(p(fw, .tap), quiet: 250, cap: 4400, tree: true, host: true)
            expect(p(fw, .text), quiet: 250, cap: 4400, tree: true, host: true)
            expect(p(fw, .scroll), quiet: 450, cap: 4400, backoff: 150, host: true)
        }
    }

    func testAndroid() {
        let caps: [(AppUIFramework?, Int)] = [(.androidView, 1700), (.compose, 1300), (.reactNative, 2300),
                                              (.flutter, 1400), (nil, 2300), (.swiftUI, 2300)]
        for (fw, cap) in caps {
            expect(p(fw, android: true, .scroll), quiet: 320, cap: cap, host: false)
            for kind in [ImageSettleActionKind.tap, .text] {
                let plan = p(fw, android: true, kind)
                XCTAssertEqual(plan.quietMs, 320)
                XCTAssertEqual(plan.capMs, cap)
                XCTAssertFalse(plan.waitEvent)
                XCTAssertFalse(plan.armTree)
                XCTAssertEqual(plan.backoffMs, 0)
            }
        }
    }

    func testKindForBridgePath() {
        for path in ["/swipe", "/drag", "/scrollAction"] { XCTAssertEqual(ImageSettlePlan.kind(forBridgePath: path), .scroll) }
        for path in ["/type", "/clear", "/pressEnter"] { XCTAssertEqual(ImageSettlePlan.kind(forBridgePath: path), .text) }
        for path in ["/tap", "/press", "/snapshot", "/unknown"] { XCTAssertEqual(ImageSettlePlan.kind(forBridgePath: path), .tap) }
    }

    func testImageModeEnabled() {
        XCTAssertTrue(ImageSettlePlan.imageModeEnabled(environment: [:]))
        XCTAssertTrue(ImageSettlePlan.imageModeEnabled(environment: ["FT_SETTLE_MODE": ""]))
        XCTAssertTrue(ImageSettlePlan.imageModeEnabled(environment: ["FT_SETTLE_MODE": "image"]))
        XCTAssertFalse(ImageSettlePlan.imageModeEnabled(environment: ["FT_SETTLE_MODE": "tree"]))
    }

    // MARK: - 実行機

    private func list() -> ElementInfo {
        ElementInfo(ref: 1, type: "scrollView", identifier: "list_rows", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 100, width: 300, height: 600), depth: 1)
    }

    private func swipe(framework: AppUIFramework?, android: Bool = false, imageMode: Bool = true)
        async -> (count: Int, bypass: Bool) {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[list()]])
        let executor = StepExecutor(driver: driver, isAndroid: android, tunables: RunTunables(),
                                    uiFramework: framework)
        executor.imageSettleEnabled = imageMode
        _ = await executor.execute(FlowStep(action: "swipe", direction: "up"))
        return (driver.snapshotCallCount, executor.nextResolveBypassesCache)
    }

    /// UIKit 系はホストの操作後の木の整定(静止した木で2枚)を払わず、自前描画は払う
    func testImageModeSkipsPostSwipeTreeSettleOnlyWhereThePlanSaysSo() async {
        let uikit = await swipe(framework: .swiftUI)
        let compose = await swipe(framework: .compose)
        XCTAssertEqual(compose.count - uikit.count, 2)
        XCTAssertGreaterThan(uikit.count, 0, "操作前の整定は残る")
        XCTAssertTrue(uikit.bypass, "飛ばしても次の解決はキャッシュを迂回する")
    }

    func testTreeModeKeepsThePostSwipeSettleEverywhere() async {
        let tree = await swipe(framework: .swiftUI, imageMode: false)
        let image = await swipe(framework: .swiftUI)
        XCTAssertEqual(tree.count - image.count, 2)
        let android = await swipe(framework: .androidView, android: true)
        let androidTree = await swipe(framework: .androidView, android: true, imageMode: false)
        XCTAssertEqual(androidTree.count - android.count, 2)
    }
}
