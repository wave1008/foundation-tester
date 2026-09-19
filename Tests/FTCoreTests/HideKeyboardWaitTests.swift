// Android の `hideKeyboard` の後、次のロケータ操作の解決で木のキーボードが消えるまで待つ
// (StepExecutor.pendingHideKeyboardWait)。Pixel 3a(Android 12)の Flutter で、IME が閉じ始めてから
// 約 5.4 秒、木がキーボードを申告し続けて下端のタブバーを落とし、次の tap が解決できなかった(P8)。

import XCTest
@testable import FTCore

final class HideKeyboardWaitTests: XCTestCase {

    private let keyboard = FTRect(x: 0, y: 500, width: 400, height: 300)

    private func tab() -> ElementInfo {
        ElementInfo(ref: 7, type: "button", identifier: "tab_home", label: "ホーム", value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 740, width: 130, height: 50), depth: 1)
    }

    private func title() -> ElementInfo {
        ElementInfo(ref: 1, type: "staticText", identifier: "txt_title", label: "テキスト入力", value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 40, width: 200, height: 30), depth: 1)
    }

    private func isPassed(_ status: StepResult.Status) -> Bool {
        if case .passed = status { return true }
        if case .passedViaFallback = status { return true }
        return false
    }

    /// 木のキーボードが 6 回の読みのあいだ残り、7 回目でタブが戻る。解決の既定の待ち(約 0.7 秒)では
    /// 届かない長さ = 待たなければ赤
    func testTapAfterHideKeyboardWaitsForTheTreeToDropTheKeyboard() async throws {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements:
            Array(repeating: [title()], count: 6) + [[title(), tab()]])
        driver.keyboardFrames = Array(repeating: keyboard, count: 6) + [nil]
        driver.bypassSupported = true
        let executor = StepExecutor(driver: driver, isAndroid: true)
        _ = await executor.execute(FlowStep(action: "hideKeyboard"))
        let tap = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "tab_home")))
        XCTAssertTrue(isPassed(tap.status), "\(tap.status)")
        XCTAssertNil(executor.pendingHideKeyboardWait, "消費したら下りる")
    }

    /// キーボードが既に消えていれば、読みの回数は tap 単独と同じ(追加の費用ゼロ)
    func testNoExtraReadsWhenTheKeyboardIsAlreadyGone() async throws {
        func reads(hideFirst: Bool) async -> Int {
            let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[title(), tab()]])
            driver.bypassSupported = true
            let executor = StepExecutor(driver: driver, isAndroid: true)
            if hideFirst { _ = await executor.execute(FlowStep(action: "hideKeyboard")) }
            let before = driver.snapshotCallCount
            _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "tab_home")))
            return driver.snapshotCallCount - before
        }
        let plain = await reads(hideFirst: false)
        let afterHide = await reads(hideFirst: true)
        XCTAssertEqual(afterHide, plain)
    }

    func testIOSDoesNotArmTheWait() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[title()]])
        let executor = StepExecutor(driver: driver, isAndroid: false)
        _ = await executor.execute(FlowStep(action: "hideKeyboard"))
        XCTAssertNil(executor.pendingHideKeyboardWait)
    }

    /// 上限は hideKeyboard ステップの待ち時間(既定は FlowStep.defaultWaitSeconds)。消えなくても打ち切って進む
    func testTheWaitStopsAtTheHideKeyboardStepTimeout() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[title()]])
        driver.keyboardFrame = keyboard
        driver.bypassSupported = true
        let executor = StepExecutor(driver: driver, isAndroid: true)
        _ = await executor.execute(FlowStep(action: "hideKeyboard", timeout: 0.3))
        XCTAssertEqual(executor.pendingHideKeyboardWait, 0.3)
        let clock = ContinuousClock()
        let start = clock.now
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "tab_home"), timeout: 0))
        XCTAssertLessThan(clock.now - start, .seconds(3), "上限 0.3 秒で打ち切る(既定の 5 秒まで待たない)")

        let defaulted = StepExecutor(driver: driver, isAndroid: true)
        _ = await defaulted.execute(FlowStep(action: "hideKeyboard"))
        XCTAssertEqual(defaulted.pendingHideKeyboardWait, 5, "省略時は既定の待ち時間(5 秒)")
    }

    /// DSL の hideKeyboard() は StepExecutor を通す(ドライバを直に呼ぶと待ちの印が立たない = 直す前の形)
    func testTheDSLRoutesHideKeyboardThroughTheExecutor() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTDSL/CommandsAppControl.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public func hideKeyboard("))
        let end = try XCTUnwrap(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        let body = source[start.upperBound..<end.lowerBound]
        XCTAssertTrue(body.contains("FlowStep(action: \"hideKeyboard\")") && body.contains(".perform(step:"),
                      "hideKeyboard() が executor を通っていない")
        XCTAssertFalse(body.contains("performCustom"), "ドライバを直に呼んでいる")
    }
}
