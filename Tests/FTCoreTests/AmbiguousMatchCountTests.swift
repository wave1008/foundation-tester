// 操作の対象を解決したとき、セレクタが2件以上に一致した数を StepOutcome に載せる(ft_batch が行に添える)。
// 序数の指定は利用者が1つを選んでいるので数えない

import XCTest
@testable import FTCore

final class AmbiguousMatchCountTests: XCTestCase {

    private func okButton(ref: Int, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: nil, label: "OK", value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 10, y: y, width: 100, height: 40), depth: 1)
    }

    func testDuplicateLabelIsCounted() async {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log,
                                   snapshotElements: [[okButton(ref: 1, y: 100), okButton(ref: 2, y: 300)]])
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "OK")))
        XCTAssertEqual(outcome.ambiguousMatchCount, 2)
    }

    func testOrdinalSelectorIsNotCounted() async {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log,
                                   snapshotElements: [[okButton(ref: 1, y: 100), okButton(ref: 2, y: 300)]])
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "OK", index: 1)))
        XCTAssertNil(outcome.ambiguousMatchCount)
    }
}
