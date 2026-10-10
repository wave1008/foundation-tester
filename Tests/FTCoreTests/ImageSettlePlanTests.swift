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

    /// report = 偽ドライバの `lastGestureImageSettleCapped`(nil = ブリッジが画像整定していない = in-app・tree・adb の drag)
    private func run(_ step: FlowStep, framework: AppUIFramework?, android: Bool = false, report: Bool?,
                     elements: [ElementInfo]? = nil) async -> (count: Int, bypass: Bool, outcome: StepOutcome) {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [elements ?? [list()]])
        driver.gestureImageSettleCapped = report
        let executor = StepExecutor(driver: driver, isAndroid: android, tunables: RunTunables(),
                                    uiFramework: framework)
        let outcome = await executor.execute(step)
        return (driver.snapshotCallCount, executor.nextResolveBypassesCache, outcome)
    }

    private let swipeUp = FlowStep(action: "swipe", direction: "up")

    /// ブリッジが画像整定した swipe の後、UIKit 系はホストの木の整定(静止した木で2枚)を払わず、自前描画は払う
    func testBridgeImageSettledSkipsPostSwipeTreeSettleOnlyWhereThePlanSaysSo() async {
        let uikit = await run(swipeUp, framework: .swiftUI, report: false)
        let compose = await run(swipeUp, framework: .compose, report: false)
        XCTAssertEqual(compose.count - uikit.count, 2)
        XCTAssertGreaterThan(uikit.count, 0, "操作前の整定は残る")
        XCTAssertTrue(uikit.bypass, "飛ばしても次の解決はキャッシュを迂回する")
    }

    /// ブリッジの申告が無い(in-app・`FT_SETTLE_MODE=tree`・adb の drag)なら、計画が省けると言っても木の整定を払う
    /// (誰も整定していないのに省くと、動いている木を次の解決が掴む)
    func testNoBridgeReportKeepsThePostSwipeSettle() async {
        let reported = await run(swipeUp, framework: .swiftUI, report: false)
        let unreported = await run(swipeUp, framework: .swiftUI, report: nil)
        XCTAssertEqual(unreported.count - reported.count, 2)
        let android = await run(swipeUp, framework: .androidView, android: true, report: false)
        let androidUnreported = await run(swipeUp, framework: .androidView, android: true, report: nil)
        XCTAssertEqual(androidUnreported.count - android.count, 2)
    }

    /// 上限まで動き続けた申告は、ホストの整定を省いた回でも settle-capped として残す(黙って消さない)
    func testCappedReportIsNotedEvenWhenTheHostSettleIsSkipped() async {
        let capped = await run(swipeUp, framework: .swiftUI, report: true)
        XCTAssertTrue(capped.outcome.notes.contains(.settleCapped), "\(capped.outcome.notes)")
        let still = await run(swipeUp, framework: .swiftUI, report: false)
        XCTAssertFalse(still.outcome.notes.contains(.settleCapped), "\(still.outcome.notes)")
        let scroll = await run(FlowStep(action: "scroll", direction: "down"), framework: .swiftUI, report: true)
        XCTAssertTrue(scroll.outcome.notes.contains(.settleCapped), "scrollDown の本ごとの申告も拾う: \(scroll.outcome.notes)")
    }

    /// 木の整定を省けるのは drag(swipeBy)だけ。ダブルタップはブリッジが画像整定しない経路で、申告は前の swipe の
    /// 値が残っているだけ(消さない)なので、申告があっても払う
    func testOnlyDragAmongGesturesMaySkipTheHostSettle() async {
        let swipeBy = FlowStep(action: "swipeBy", dxRatio: 0, dyRatio: -0.5)
        let dragReported = await run(swipeBy, framework: .swiftUI, report: false, elements: [])
        let dragUnreported = await run(swipeBy, framework: .swiftUI, report: nil, elements: [])
        XCTAssertEqual(dragUnreported.count - dragReported.count, 2)
        let doubleTap = FlowStep(action: "doubleTap", locator: FlowLocator(id: "list_rows"))
        let stale = await run(doubleTap, framework: .swiftUI, report: false)
        let none = await run(doubleTap, framework: .swiftUI, report: nil)
        XCTAssertEqual(stale.count, none.count, "ダブルタップは前の swipe の申告で整定を省かない")
    }
}
