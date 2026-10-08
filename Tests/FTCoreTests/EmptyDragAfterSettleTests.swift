// 木が動きに遅れるエンジン(XCUITest)では、探索の終わりの空打ちを「止まった後の位置」で撃つ。
// 見つけた瞬間の木は慣性の途中なので、その座標で押すと隣の行の上で押して離し、クリックが成立する
// (実測 E2EX-CMP / Flutter のホームの最下段: `#nav_infinite` を探して隣の `#nav_native` の画面へ移った)

import XCTest
@testable import FTCore

/// 払う前は対象が木に無い。払った直後の1枚だけ対象が動いている途中(y=600)、以後は止まった位置(y=500)
private final class FlingThenRestDriver: AppDriver {
    let lags: Bool
    private(set) var swiped = false
    private(set) var snapsSinceSwipe = 0
    private(set) var emptyDragStartY: [Double] = []

    init(lags: Bool) { self.lags = lags }

    var treeLagsBehindMotion: Bool { lags }

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
    func swipe(_ direction: FTSwipeDirection) async throws { swiped = true }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swiped = true
    }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        emptyDragStartY.append(fromY)
    }

    func snapshot() async throws -> SnapshotResponse {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        var elements = [
            ElementInfo(ref: 1, type: "other", identifier: "list", label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 100, width: 402, height: 700), depth: 1),
            ElementInfo(ref: 2, type: "button", identifier: "row_a", label: "A", value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 16, y: 120, width: 370, height: 56), depth: 2),
            ElementInfo(ref: 3, type: "button", identifier: "row_b", label: "B", value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 16, y: 180, width: 370, height: 56), depth: 2),
        ]
        if swiped {
            snapsSinceSwipe += 1
            let y: Double = snapsSinceSwipe == 1 ? 600 : 500
            elements.append(ElementInfo(ref: 4, type: "button", identifier: "target", label: "対象", value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 2))
        }
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }
}

final class EmptyDragAfterSettleTests: XCTestCase {

    private func run(lags: Bool) async -> FlingThenRestDriver {
        let driver = FlingThenRestDriver(lags: lags)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"), direction: "up", maxSwipes: 3)
        _ = await StepExecutor(driver: driver, releasesScrollTouch: true, isAndroid: false, tunables: RunTunables(),
                               uiFramework: .compose).execute(step)
        return driver
    }

    func testXCUITestDragsAtTheRestingPosition() async {
        let driver = await run(lags: true)
        XCTAssertEqual(driver.emptyDragStartY.count, 1, "空打ちが撃たれていない = この経路を通っていない")
        XCTAssertEqual(driver.emptyDragStartY.first ?? 0, 528, accuracy: 1, "止まった後の位置(500 + 56/2)で押す")
    }

    /// 対照: 遅れないエンジンは見つけた瞬間の位置で撃つ(従来どおり)
    func testNonLaggingEngineKeepsTheFoundPosition() async {
        let driver = await run(lags: false)
        XCTAssertEqual(driver.emptyDragStartY.count, 1)
        XCTAssertEqual(driver.emptyDragStartY.first ?? 0, 628, accuracy: 1)
    }

    /// 止まるのを待つ間に対象が流れ去ったら、失敗せず探索を続けて見つけ直す(Flutter の sticky の実測の形)
    func testSearchContinuesWhenTheTargetDriftsAwayWhileSettling() async {
        let driver = DriftAwayDriver()
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"), direction: "up", maxSwipes: 4)
        let outcome = await StepExecutor(driver: driver, releasesScrollTouch: true, isAndroid: false,
                                         tunables: RunTunables(), uiFramework: .compose).execute(step)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertGreaterThanOrEqual(driver.swipes, 2, "流れ去った後にもう一度送っていない")
        XCTAssertEqual(driver.emptyDragStartY, [528], "見つけ直した後の止まった位置で1回だけ空打ちする")
    }
}

/// 1本目の払いの直後の1枚だけ対象が見え(y=600)、止まると木から消える(流れ去った)。2本目の払いの後は y=500 で止まる
private final class DriftAwayDriver: AppDriver {
    private(set) var swipes = 0
    private var snapsSinceSwipe = 0
    private(set) var emptyDragStartY: [Double] = []
    var treeLagsBehindMotion: Bool { true }

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
    func swipe(_ direction: FTSwipeDirection) async throws { swipes += 1; snapsSinceSwipe = 0 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        swipes += 1; snapsSinceSwipe = 0
    }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        if fromY == toY || abs(toY - fromY) < 60 { emptyDragStartY.append(fromY) } else { swipes += 1; snapsSinceSwipe = 0 }
    }

    func snapshot() async throws -> SnapshotResponse {
        snapsSinceSwipe += 1
        var elements = [
            ElementInfo(ref: 1, type: "other", identifier: "list", label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 100, width: 402, height: 700), depth: 1),
            ElementInfo(ref: 2, type: "button", identifier: "row_a", label: "A", value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 16, y: 120, width: 370, height: 56), depth: 2),
            ElementInfo(ref: 3, type: "button", identifier: "row_b", label: "B", value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 16, y: 180, width: 370, height: 56), depth: 2),
        ]
        let y: Double? = swipes == 1 ? (snapsSinceSwipe == 1 ? 600 : nil) : (swipes >= 2 ? 500 : nil)
        if let y {
            elements.append(ElementInfo(ref: 4, type: "button", identifier: "target", label: "対象", value: nil,
                                        placeholder: nil, enabled: true,
                                        frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 2))
        }
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }
}
