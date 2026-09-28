// スクロール探索の打ち切りは、最後に動いてから `edgeClaimGraceAfterMove` 経つまで待つ。
// witness: E2EX-iOS の無限スクロール(SwiftUI。末尾に着いてから 0.8 秒後に 20 行足す)で、
// tap("#row_i_57", scroll: .down) が loaded=40 のまま「端に着いた」と打ち切られた。

import XCTest
@testable import FTCore

final class ScrollSearchLateContentTests: XCTestCase {

    /// **witness**: 末尾で 0.8 秒後に続きを足す一覧の、2回目の読み込みの先の行へ届く
    func testSearchWaitsForContentAppendedAfterReachingTheEnd() async throws {
        let driver = LateAppendingListDriver(appendDelay: 0.8)
        let executor = StepExecutor(driver: driver, isAndroid: false)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_35"),
                            direction: "up", maxSwipes: 30)
        var phase = StepExecutor.PhaseAccumulator()
        let result = try await executor.runScrollSearch(step: step, phase: &phase)
        XCTAssertTrue(result.found, "loaded=\(driver.available)")
    }

    /// 逆向き: 続きが来ない一覧は今までどおり打ち切る(上限まで振り続けない)
    func testSearchStillStopsAtAListThatNeverGrows() async throws {
        let driver = LateAppendingListDriver(appendDelay: nil)
        let executor = StepExecutor(driver: driver, isAndroid: false)
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_35"),
                            direction: "up", maxSwipes: 30)
        var phase = StepExecutor.PhaseAccumulator()
        let result = try await executor.runScrollSearch(step: step, phase: &phase)
        XCTAssertFalse(result.found)
        XCTAssertTrue(result.stoppedUnmoving)
        XCTAssertLessThan(driver.swipes, 12, "端に着いた後も振り続けた(\(driver.swipes) 回)")
    }
}

/// 8 行の窓を持つ一覧。1回の送りで 4 行進む。末尾に着いてから `appendDelay` 秒後に 20 行足す(最大 100)
private final class LateAppendingListDriver: AppDriver {
    private let appendDelay: TimeInterval?
    private(set) var available = 20
    private(set) var swipes = 0
    private var top = 0
    private var endReachedAt: Date?
    private let window = 8

    init(appendDelay: TimeInterval?) { self.appendDelay = appendDelay }

    private func advance() {
        swipes += 1
        top = min(top + 4, available - window)
        if top == available - window, endReachedAt == nil { endReachedAt = Date() }
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
    func swipe(_ direction: FTSwipeDirection) async throws { advance() }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        advance()
    }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws { advance() }

    func snapshot() async throws -> SnapshotResponse {
        if let appendDelay, let reached = endReachedAt, Date().timeIntervalSince(reached) >= appendDelay,
           available < 100 {
            available += 20
            endReachedAt = nil
        }
        var elements = [ElementInfo(ref: 1, type: "scrollView", identifier: "list", label: nil, value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 0, y: 0, width: 400, height: 800), depth: 0,
                                    scrollable: true)]
        for (i, row) in (top..<(top + window)).enumerated() {
            elements.append(ElementInfo(ref: 2 + i, type: "button", identifier: String(format: "row_%02d", row),
                                        label: nil, value: nil, placeholder: nil, enabled: true,
                                        frame: FTRect(x: 16, y: Double(i) * 100, width: 368, height: 90),
                                        depth: 1))
        }
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                elements: elements, truncatedCount: 0)
    }
}
