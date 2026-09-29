// swipe・scroll も flick と同じく、指の経路を決める枠を静止した木から取る
// (StepExecutor+DirectActions.swift。flick の実測は FlickSettleTests)。

import XCTest
@testable import FTCore

final class GestureSettleTests: XCTestCase {

    /// 木を呼び出し順に返し、経路つきのスワイプを記録する
    private final class PathDriver: AppDriver {
        var trees: [[ElementInfo]]
        let keyboard: FTRect?
        private(set) var snapshots = 0
        private(set) var paths: [FTSwipePath?] = []
        init(trees: [[ElementInfo]], keyboard: FTRect? = nil) { self.trees = trees; self.keyboard = keyboard }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            defer { snapshots += 1 }
            return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                    elements: trees[min(snapshots, trees.count - 1)], truncatedCount: 0,
                                    keyboardShown: keyboard != nil, keyboardFrame: keyboard)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws { paths.append(nil) }
        func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
            paths.append(path)
        }
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func list(x: Double) -> ElementInfo {
        ElementInfo(ref: 1, type: "scrollView", identifier: "list_rows", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: 100, width: 300, height: 400), depth: 1)
    }

    /// 遷移中(右から滑り込んでいる)→ 止まった、の順に木を返す
    private var sliding: [[ElementInfo]] { [[list(x: 350)], [list(x: 0)], [list(x: 0)]] }

    func testScrollWithAScrollFrameIsAimedAtTheSettledFrame() async throws {
        try XCTSkipUnless(StepExecutor.coordinateScrollEnabled, "FT_SCROLL_TARGET=legacy では枠を使わない")
        let driver = PathDriver(trees: sliding)
        let executor = StepExecutor(driver: driver, isAndroid: true)
        var step = FlowStep(action: "scroll", direction: "up", maxSwipes: 1)
        step.scrollFrame = FlowLocator(id: "list_rows")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        let path = try XCTUnwrap(driver.paths.first ?? nil, "scrollFrame があれば経路を付ける")
        XCTAssertLessThan(path.fromX, 300, "止まった枠(x 0〜300)の中を払う: \(path)")
        XCTAssertTrue(outcome.notes.contains(.settledBeforeGesture))
    }

    /// swipe が枠を使うのはキーボードが出ているときだけ(避けるため)。そのときも静止した木から取る
    func testSwipeWithAKeyboardWaitsForTheScreenToSettle() async throws {
        let driver = PathDriver(trees: sliding, keyboard: FTRect(x: 0, y: 600, width: 400, height: 200))
        let executor = StepExecutor(driver: driver, isAndroid: true)

        let outcome = await executor.execute(FlowStep(action: "swipe", direction: "up"))

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(outcome.notes.contains(.settledBeforeGesture))
        XCTAssertGreaterThanOrEqual(driver.snapshots, 3, "静止を確かめるまで木を撮る")
    }

    func testStillScreenDoesNotNote() async throws {
        let driver = PathDriver(trees: [[list(x: 0)]])
        let executor = StepExecutor(driver: driver, isAndroid: true)
        var step = FlowStep(action: "scroll", direction: "up", maxSwipes: 1)
        step.scrollFrame = FlowLocator(id: "list_rows")

        let outcome = await executor.execute(step)

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(outcome.notes.contains(.settledBeforeGesture))
    }
}
