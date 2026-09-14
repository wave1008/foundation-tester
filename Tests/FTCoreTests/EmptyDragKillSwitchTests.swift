// `FT_EMPTY_DRAG=off` は空打ちが今も要るかを E2E の規模で測るための保守者の殺しスイッチ
// (2026-09-12 の計測: 止めると E2E-CMP / ios-xcuitest の S0080 が 3/3 で `selected=-` = 吸われる。
// 空打ちは今も要る)。利用者向けの口ではないので、既定(未設定)では効かないことも固定する

import XCTest
@testable import FTCore

final class EmptyDragKillSwitchTests: XCTestCase {
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = ProcessInfo.processInfo.environment["FT_EMPTY_DRAG"]
    }

    override func tearDown() {
        if let saved { setenv("FT_EMPTY_DRAG", saved, 1) } else { unsetenv("FT_EMPTY_DRAG") }
        super.tearDown()
    }

    func testOffDisablesTheReliefDragEvenForCompose() {
        setenv("FT_EMPTY_DRAG", "off", 1)
        let executor = StepExecutor(driver: FakeAppDriver(name: "p", log: CallLog()),
                                    releasesScrollTouch: true, isAndroid: false, uiFramework: .compose)
        XCTAssertFalse(executor.shouldEmptyDrag)
    }

    func testUnsetKeepsTheDefault() {
        unsetenv("FT_EMPTY_DRAG")
        let executor = StepExecutor(driver: FakeAppDriver(name: "p", log: CallLog()),
                                    releasesScrollTouch: true, isAndroid: false, uiFramework: .compose)
        XCTAssertTrue(executor.shouldEmptyDrag)
    }
}
