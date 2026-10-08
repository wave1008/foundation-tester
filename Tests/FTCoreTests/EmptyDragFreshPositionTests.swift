// 木が動きに遅れるエンジン(XCUITest)では、探索の終わりの空打ちを押す直前に木を1枚撮り直し、その座標で押す(待たない)。
// 見つけた木は慣性の途中で、押すまでに一覧が止まっていると古い座標は隣の行の上になり、隣のクリックが成立する
// (E2EX-CMP / Flutter のホームの最下段で隣の画面へ移った)。止まるのを待つ形は試して取り消した(maintainer-notes §74.10)

import XCTest
@testable import FTCore

/// 払う前は対象が木に無い。払った直後の1枚目は対象が y=600(慣性の途中)、2枚目以降は `afterY`(止まった位置。nil = 木に居ない)
private final class StaleThenFreshDriver: AppDriver {
    let lags: Bool
    let afterY: Double?
    private(set) var swiped = false
    private var snapsSinceSwipe = 0
    private(set) var emptyDragStartY: [Double] = []

    init(lags: Bool, afterY: Double?) {
        self.lags = lags
        self.afterY = afterY
    }

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
            let y: Double? = snapsSinceSwipe == 1 ? 600 : afterY
            if let y {
                elements.append(ElementInfo(ref: 4, type: "button", identifier: "target", label: "対象", value: nil,
                                            placeholder: nil, enabled: true,
                                            frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 2))
            }
        }
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }
}

final class EmptyDragFreshPositionTests: XCTestCase {

    private func emptyDragY(lags: Bool, afterY: Double?) async -> [Double] {
        let driver = StaleThenFreshDriver(lags: lags, afterY: afterY)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "target"), direction: "up", maxSwipes: 3)
        _ = await StepExecutor(driver: driver, releasesScrollTouch: true, isAndroid: false, tunables: RunTunables(),
                               uiFramework: .compose).execute(step)
        return driver.emptyDragStartY
    }

    func testXCUITestPressesAtThePositionRetakenJustBefore() async {
        let ys = await emptyDragY(lags: true, afterY: 500)
        XCTAssertEqual(ys.count, 1, "空打ちが撃たれていない = この経路を通っていない")
        XCTAssertEqual(ys.first ?? 0, 528, accuracy: 1, "撮り直した位置(500 + 56/2)で押す")
    }

    /// 対照: 遅れないエンジンは見つけた木の位置で押す(従来どおり)
    func testNonLaggingEngineKeepsTheFoundPosition() async {
        let ys = await emptyDragY(lags: false, afterY: 500)
        XCTAssertEqual(ys.first ?? 0, 628, accuracy: 1)
    }

    /// 撮り直した木に対象が居なければ見つけた位置のまま押す(待って探し直さない = 慣性を止める役を残す)
    func testMissingInTheRetakenTreeKeepsTheFoundPosition() async {
        let ys = await emptyDragY(lags: true, afterY: nil)
        XCTAssertEqual(ys.first ?? 0, 628, accuracy: 1)
    }
}
