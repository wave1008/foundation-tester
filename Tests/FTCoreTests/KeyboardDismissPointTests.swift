import XCTest
@testable import FTCore

/// iOS の hideKeyboard が叩く点(焦点のある欄の左 → 右 → 上 → 下の空き)と、実行機の流れ(当たり判定 → 叩く → 消えたか確かめる)
final class KeyboardDismissPointTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ id: String?, _ frame: FTRect, depth: Int,
                    focused: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: frame, depth: depth, focused: focused)
    }

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
    private let keyboard = FTRect(x: 0, y: 538, width: 402, height: 336)
    private let field = FTRect(x: 16, y: 402, width: 370, height: 64)

    /// 実測の形(住所フォーム・iOS): 全画面のスクロール容器の上に欄が並び、市区町村の欄に焦点
    private func form(extra: [ElementInfo] = []) -> [ElementInfo] {
        [el(1, "scrollView", nil, screen, depth: 0),
         el(2, "staticText", nil, FTRect(x: 56, y: 126, width: 95, height: 22), depth: 1),
         el(3, "textView", "field_city", field, depth: 1, focused: true)] + extra
    }

    private func candidates(_ elements: [ElementInfo], overlays: [FTRect] = []) -> [KeyboardDismissPoint.Choice] {
        KeyboardDismissPoint.candidates(elements: elements, screen: screen, keyboard: keyboard, overlays: overlays)
    }

    /// キーボードの上を下から上へ: 最初の候補はキーボードのすぐ上で、欄にも見出しにも乗らない
    func testScansFromJustAboveTheKeyboardUpward() throws {
        let found = candidates(form())
        let first = try XCTUnwrap(found.first)
        XCTAssertLessThan(first.y, keyboard.y)
        XCTAssertGreaterThan(first.y, field.y + field.height, "キーボードのすぐ上(欄より下)から見るはず")
        XCTAssertEqual(found.map(\.y), found.map(\.y).sorted(by: >), "下から上の順")
        for choice in found {
            XCTAssertFalse(choice.x >= field.x && choice.x <= field.x + field.width
                && choice.y >= field.y && choice.y <= field.y + field.height, "欄の上を候補にした")
        }
    }

    /// トーストのような画面幅いっぱいでない入れ物の余白は空きに数えない
    func testAToastContainerIsNotAnEmptySpot() {
        let toast = el(4, "other", "toast", FTRect(x: 24, y: 470, width: 354, height: 60), depth: 1)
        let toastText = el(5, "staticText", nil, FTRect(x: 120, y: 490, width: 160, height: 20), depth: 2)
        for choice in candidates(form(extra: [toast, toastText])) {
            XCTAssertFalse(choice.x >= 24 && choice.x <= 378 && choice.y >= 470 && choice.y <= 530, "トーストの上を候補にした")
        }
    }

    /// 木に出ない重ねウィンドウ(overlayWindowFrames)の上も除く
    func testOverlayWindowFramesAreExcluded() {
        let overlay = FTRect(x: 0, y: 470, width: 402, height: 68)
        for choice in candidates(form(), overlays: [overlay]) {
            XCTAssertFalse(choice.y >= 470 && choice.y <= 538, "重ねウィンドウの上を候補にした")
        }
    }

    // MARK: - 実行機の流れ

    private let background = TapProbeResponse(background: true, receiver: "UIView", reason: nil)

    func testIOSHideKeyboardTapsAConfirmedSpotAboveTheKeyboardAndPassesWhenTheKeyboardGoes() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [form()])
        driver.keyboardFrames = [keyboard, nil]
        driver.tapProbeAnswer = background
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "hideKeyboard"))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.coordinateTaps.count, 1)
        XCTAssertLessThan(try XCTUnwrap(driver.coordinateTaps.first).y, keyboard.y, "キーボードの上を叩くはず")
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("primary.hideKeyboard") }, "iOS はブリッジの hideKeyboard を撃たない")
        XCTAssertTrue(outcome.driverFallback?.contains("above the keyboard") == true, outcome.driverFallback ?? "nil")
    }

    /// 当たり判定に答えないエンジン(XCUITest だけ)は木だけで決めて叩き、確かめていないことを注記に出す
    func testIOSHideKeyboardFallsBackToTheTreeWhenTheEngineCannotTell() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [form()])
        driver.keyboardFrames = [keyboard, nil]
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "hideKeyboard"))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.coordinateTaps.count, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(driver.coordinateTaps.first).y, 126, "木に載る最も上の要素より上は叩かない")
        XCTAssertTrue(outcome.driverFallback?.contains("chosen from the tree only") == true, outcome.driverFallback ?? "nil")
    }

    /// どの点も木に載らないものの上(トーストの窓が前面等)のまま上限まで変わらなければ叩かない
    func testIOSHideKeyboardDoesNotTapWhenEverySpotCouldReact() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [form()])
        driver.keyboardFrame = keyboard
        driver.tapProbeAnswer = TapProbeResponse(background: false, receiver: "ToastWindow",
                                                 reason: "another window is in front there (a toast or another overlay)")
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.3))
        let outcome = await executor.execute(FlowStep(action: "hideKeyboard"))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("every spot checked could react"), message)
        XCTAssertTrue(message.contains("ToastWindow"), message)
        XCTAssertTrue(driver.coordinateTaps.isEmpty)
    }

    /// トーストが消えるのを待ってから叩く(最初の木ではトーストが欄の周りを覆い、次の木で消えている)
    func testIOSHideKeyboardWaitsForAToastToGoAway() async throws {
        let log = CallLog()
        // 最初の木ではキーボードの上一面をトースト(画面幅より狭い入れ物)が覆い、次の木で消えている
        let toast = el(4, "other", "toast", FTRect(x: 1.5, y: 0, width: 399, height: 538), depth: 1)
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [form(extra: [toast]), form()])
        driver.keyboardFrames = [keyboard, keyboard, nil]
        driver.tapProbeAnswer = background
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "hideKeyboard"))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.coordinateTaps.count, 1)
    }

    func testIOSHideKeyboardFailsWithTheFactWhenTheAppKeepsTheKeyboard() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [form()])
        driver.keyboardFrame = keyboard
        driver.tapProbeAnswer = background
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.2))
        let outcome = await executor.execute(FlowStep(action: "hideKeyboard"))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("is still shown: tapping"), message)
        XCTAssertTrue(message.contains("sent Enter"), message)
        XCTAssertTrue(log.entries.contains("primary.pressEnter"), log.entries.description)
    }

    /// 背景を叩いても閉じなければ Enter を送り、閉じたら成功(Enter で欄の確定操作が走ったことを注記に出す)
    func testIOSHideKeyboardFallsBackToEnterWhenTappingDoesNotCloseIt() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [form()])
        driver.keyboardFrame = keyboard
        driver.tapProbeAnswer = background
        driver.afterPressEnter = { driver.keyboardFrame = nil }
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.2))
        let outcome = await executor.execute(FlowStep(action: "hideKeyboard"))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.coordinateTaps.count, 1, "先に背景を叩くはず")
        XCTAssertTrue(log.entries.contains("primary.pressEnter"), log.entries.description)
        XCTAssertTrue(outcome.driverFallback?.contains("so sent Enter") == true, outcome.driverFallback ?? "nil")
    }

    /// Enter へ進まない設定(MCP)なら、閉じなければ Enter を送らずに失敗
    func testIOSHideKeyboardWithoutEnterFallbackFailsWithoutSendingEnter() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [form()])
        driver.keyboardFrame = keyboard
        driver.tapProbeAnswer = background
        driver.afterPressEnter = { driver.keyboardFrame = nil }
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables(defaultTimeout: 0.2))
        executor.hideKeyboardFallsBackToEnter = false
        let outcome = await executor.execute(FlowStep(action: "hideKeyboard"))
        guard case .failed(let message) = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(message.contains("Enter was not sent"), message)
        XCTAssertFalse(log.entries.contains("primary.pressEnter"), log.entries.description)
        XCTAssertEqual(driver.coordinateTaps.count, 1)
    }

    func testIOSHideKeyboardDoesNothingWhenNoKeyboardIsShown() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [form()])
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "hideKeyboard"))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(driver.coordinateTaps.isEmpty, "キーボードが無いのに叩いた")
    }
}
