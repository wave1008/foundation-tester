// flick は枠を静止した木から取る(StepExecutor+DirectActions.swift の executeDirectFlick)。
// 実測(Android の CMP / Flutter / RN): 画面遷移のタップから約 0.5 秒後に撃った flick で、リストが 1pt も動かず
// `top=row_01` のまま赤になった(1 枚だけ撮った木の枠 = 遷移で動いている最中か古い枠へ指を置いた)。

import XCTest
@testable import FTCore

final class FlickSettleTests: XCTestCase {

    private func list(x: Double) -> ElementInfo {
        ElementInfo(ref: 1, type: "scrollView", identifier: "list_rows", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: 100, width: 300, height: 600), depth: 1)
    }

    private func flick() -> FlowStep {
        var step = FlowStep(action: "flick", direction: "bottomToTop", maxSwipes: 1)
        step.scrollFrame = FlowLocator(id: "list_rows")
        return step
    }

    func testFlickIsAimedAtTheSettledFrameAndNotesThatItWaited() async throws {
        try XCTSkipUnless(StepExecutor.coordinateScrollEnabled, "FT_SCROLL_TARGET=legacy では枠を使わない")
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [
            [list(x: 350)],   // 遷移中(右から滑り込んでいる)
            [list(x: 0)],     // 止まった
            [list(x: 0)],
        ])
        let executor = StepExecutor(driver: driver, isAndroid: true)

        let outcome = await executor.execute(flick())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        let drag = try XCTUnwrap(driver.dragCalls.first)
        XCTAssertLessThan(drag.0, 300, "止まった枠(x 0〜300)の中に指を置く: \(drag)")
        XCTAssertTrue(outcome.notes.contains(.settledBeforeFlick))
    }

    func testFlickOnAStillScreenDoesNotNote() async throws {
        try XCTSkipUnless(StepExecutor.coordinateScrollEnabled, "FT_SCROLL_TARGET=legacy では枠を使わない")
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[list(x: 0)]])
        let executor = StepExecutor(driver: driver, isAndroid: true)

        let outcome = await executor.execute(flick())

        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.dragCalls.count, 1)
        XCTAssertFalse(outcome.notes.contains(.settledBeforeFlick))
    }
}
