// `type` がソフトキーボードを押し上げた直後、次のロケータ操作(tap 等)の解決を
// `settledSignature` で押し上げアニメーションの収束まで待ってから行う
// (StepExecutor.pendingTypeKeyboardCheck)。
//
// 実機を LAN(往復48ms)で回した実測(2026-09-16): WebView への `type` で 116〜134pt 押し上がる
// **最中**に次の `tap` が解決し、押し上げ前の座標を撃って別要素に当たった
// (E2E-iOS S0010・11 本中 5 本)。nextResolveBypassesCache(Android の a11y キャッシュ迂回)とは
// 別物 —— iOS in-app はキャッシュを持たないので、要るのは「1枚撮り直す」ではなく「収束を待つ」。
//
// **「打った後」の観測は読み返し(`verifyTypedText`)に頼らない**(2026-09-16 に設計変更)。
// 読み返しが走るのは `AppDriver.verifiesTypedText == false`(in-app エンジン)のときだけだが、
// 実測したバグは iPhone 13 実機(物理デバイス = xcuitest エンジン・`verifiesTypedText == true`)で
// 起きており、読み返しの木に頼る旧実装ではこの経路が1度も発火しなかった。
// 「打った後」は次のロケータ操作がどのみち撮る最初の `freshSnapshot` に譲ることで、
// 読み返しの有無・ドライバの能力に依存しない判定にしてある。

import XCTest
@testable import FTCore

final class TypeKeyboardSettleTests: XCTestCase {

    private func inputField(value: String?) -> ElementInfo {
        ElementInfo(ref: 1, type: "textField", identifier: "wv_input", label: nil, value: value,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 20, y: 300, width: 200, height: 40), depth: 1)
    }

    private func sendButton(y: Double) -> ElementInfo {
        ElementInfo(ref: 2, type: "button", identifier: "btn_send", label: "送信", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 20, y: y, width: 100, height: 40), depth: 1)
    }

    // MARK: - 純粋関数(keyboardShifted)

    func testKeyboardShiftedIsFalseWhenNeitherSideHasAKeyboard() {
        XCTAssertFalse(StepExecutor.keyboardShifted(before: nil, after: nil))
    }

    func testKeyboardShiftedIsTrueWhenAKeyboardAppears() {
        let frame = FTRect(x: 0, y: 600, width: 400, height: 200)
        XCTAssertTrue(StepExecutor.keyboardShifted(before: nil, after: frame))
    }

    func testKeyboardShiftedIsTrueWhenAKeyboardDisappears() {
        let frame = FTRect(x: 0, y: 600, width: 400, height: 200)
        XCTAssertTrue(StepExecutor.keyboardShifted(before: frame, after: nil))
    }

    func testKeyboardShiftedIsTrueWhenTheFrameMoves() {
        let before = FTRect(x: 0, y: 620, width: 400, height: 180)
        let after = FTRect(x: 0, y: 600, width: 400, height: 200)
        XCTAssertTrue(StepExecutor.keyboardShifted(before: before, after: after))
    }

    func testKeyboardShiftedIsFalseWhenTheFrameIsUnchanged() {
        let frame = FTRect(x: 0, y: 600, width: 400, height: 200)
        XCTAssertFalse(StepExecutor.keyboardShifted(before: frame, after: frame))
    }

    // MARK: - 配線: type がキーボードを動かしたら、次の tap の解決だけ静止を待つ
    // (エンジンを問わない。`verifiesTypedText == true` = xcuitest 相当のドライバで確かめる ——
    // これが実機バグの再現エンジンそのもの)

    /// **実機バグの再現形**: 読み返しを持たないドライバ(xcuitest 相当)で type → tap を行い、
    /// 待っている間に木が実際に変わった(= 待たなければ古い座標を掴んでいた)回。
    /// 注記が付き、印は消費される
    func testTapAfterTypeThatShiftsTheKeyboardWaitsAndNotesWhenItActuallyRescues() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(value: nil), sendButton(y: 700)], // #1 type の解決(打つ前・キーボード無し)
            [inputField(value: nil), sendButton(y: 700)], // #2 tap の最初の解決(= 打った後の観測。キーボード出現)
            [inputField(value: nil), sendButton(y: 520)], // #3 settledSignature 初回(押し上げ中)
            [inputField(value: nil), sendButton(y: 480)], // #4 まだ動いている(#5 はこれを繰り返す)
        ])
        driver.keyboardFrames = [nil, FTRect(x: 0, y: 600, width: 400, height: 200)]
        // **実機(iPhone 13)は xcuitest エンジン = 読み返しを持たない**。ここを true にしたまま
        // 発火することが、今回直した欠陥(読み返しに頼ると発火しない)の再発防止そのもの
        driver.verifiesTypedText = true
        let executor = StepExecutor(driver: driver, isAndroid: false)

        let typeOutcome = await executor.execute(
            FlowStep(action: "type", locator: FlowLocator(id: "wv_input"), text: "hello"))
        guard case .passed = typeOutcome.status else { return XCTFail("\(typeOutcome.status)") }
        XCTAssertTrue(executor.pendingTypeKeyboardCheck, "次の解決で比べる印が立つはず(読み返しは通らない)")

        let tapOutcome = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_send")))

        guard case .passed = tapOutcome.status else { return XCTFail("\(tapOutcome.status)") }
        XCTAssertFalse(executor.pendingTypeKeyboardCheck, "消費したら印は下りるはず")
        XCTAssertTrue(tapOutcome.notes.contains(.settledAfterKeyboard),
                      "待っている間に木が変わったので注記が付くはず")
        XCTAssertEqual(driver.snapshotCallCount, 5,
                       "type解決(1)+tapの最初の解決(1)+settle(初回+2周)(3) = 5(読み返しは走らない)")
    }

    /// type がキーボードを動かしても、次の tap の時点で既に静止していれば(settledSignature の
    /// 最初の2枚が一致)、待ちは消費されるが「救えた」わけではないので注記は付かない
    /// (guard-retaken と同じ思想)。こちらも読み返しを持たないドライバで確かめる
    func testTapAfterTypeThatShiftsTheKeyboardDoesNotNoteWhenAlreadySettled() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(value: nil), sendButton(y: 700)],
            [inputField(value: nil), sendButton(y: 480)],
            [inputField(value: nil), sendButton(y: 480)],
        ])
        driver.keyboardFrames = [nil, FTRect(x: 0, y: 600, width: 400, height: 200)]
        driver.verifiesTypedText = true
        let executor = StepExecutor(driver: driver, isAndroid: false)

        _ = await executor.execute(
            FlowStep(action: "type", locator: FlowLocator(id: "wv_input"), text: "hello"))
        XCTAssertTrue(executor.pendingTypeKeyboardCheck)

        let tapOutcome = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_send")))

        guard case .passed = tapOutcome.status else { return XCTFail("\(tapOutcome.status)") }
        XCTAssertFalse(executor.pendingTypeKeyboardCheck, "消費はする")
        XCTAssertFalse(tapOutcome.notes.contains(.settledAfterKeyboard),
                       "最初から静止していたので待った甲斐は無い = 注記は付かない")
    }

    /// キーボードが動かなければ、従来どおり印は立ってもコストはゼロ(比較だけ)。
    /// 読み返しを持つドライバ(in-app 相当)でも、そちらの固定費(読み返し1回)以外は増えないことを
    /// 合わせて確かめる
    func testTapAfterTypeWithoutAKeyboardChangeDoesNotWaitForSettle() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(value: nil), sendButton(y: 700)],
            [inputField(value: "hello"), sendButton(y: 700)],
        ])
        driver.verifiesTypedText = false
        let executor = StepExecutor(driver: driver, isAndroid: false)

        _ = await executor.execute(
            FlowStep(action: "type", locator: FlowLocator(id: "wv_input"), text: "hello"))
        // 読み返しを持つドライバでも印は立つ(判定材料は「次の1枚」であって読み返しではない)が、
        // 消費した時点でキーボードが動いていなければ settledSignature は呼ばれない
        XCTAssertTrue(executor.pendingTypeKeyboardCheck)

        let tapOutcome = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_send")))

        guard case .passed = tapOutcome.status else { return XCTFail("\(tapOutcome.status)") }
        XCTAssertFalse(tapOutcome.notes.contains(.settledAfterKeyboard))
        XCTAssertEqual(driver.snapshotCallCount, 3,
                       "type解決(1)+読み返し(1)+tap解決(1) = 3(キーボードは動いていないので settle は通らない)")
    }

    // MARK: - M22: secure 欄では iOS がキーボードを一度隠して出し直す(2026-09-17 実測)
    // 打っている間と type が返ってから約 0.8 秒は画面外・その間 0.45 秒ほど木が静止するので、
    // 整定待ちだけだと隠れている間に「静止した」と抜け、戻って 64pt 押し上がる前の座標で次の tap を撃った

    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
    private let shown = FTRect(x: 0, y: 600, width: 400, height: 200)
    private let hidden = FTRect(x: 0, y: 844, width: 400, height: 200)   // 画面外に申告される形

    func testKeyboardHiddenAfterTypeOnlyWhenItWasShownAndIsNowOffscreen() {
        XCTAssertTrue(StepExecutor.keyboardHiddenAfterType(
            before: shown, after: hidden, screen: screen, typedNewline: false))
        XCTAssertTrue(StepExecutor.keyboardHiddenAfterType(
            before: shown, after: nil, screen: screen, typedNewline: false))
        XCTAssertFalse(StepExecutor.keyboardHiddenAfterType(
            before: nil, after: hidden, screen: screen, typedNewline: false), "打つ前に出ていなければ待たない")
        XCTAssertFalse(StepExecutor.keyboardHiddenAfterType(
            before: shown, after: shown, screen: screen, typedNewline: false))
        XCTAssertFalse(StepExecutor.keyboardHiddenAfterType(
            before: shown, after: hidden, screen: screen, typedNewline: true), "Enter で閉じたなら待たない")
        XCTAssertFalse(StepExecutor.keyboardOnScreen(FTRect(x: 0, y: 600, width: 400, height: 0), screen: screen),
                       "高さ 0 は出ていない")
    }

    /// 本命: 隠れている間(#2〜#4)は待ち、戻った木(#5)から整定を見る
    func testTapAfterTypeWaitsForAKeyboardThatWasHiddenToComeBack() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(value: nil), sendButton(y: 480)], // #1 type の解決(キーボードあり)
            [inputField(value: nil), sendButton(y: 700)], // #2 tap の最初の解決(隠れた = 中身が下がる)
            [inputField(value: nil), sendButton(y: 700)], // #3 まだ隠れている(ここで整定と見なすと古い座標)
            [inputField(value: nil), sendButton(y: 700)], // #4
            [inputField(value: nil), sendButton(y: 480)], // #5 戻った(押し上げ後)
        ])
        driver.keyboardFrames = [shown, hidden, hidden, hidden, shown]
        driver.verifiesTypedText = true
        let executor = StepExecutor(driver: driver, isAndroid: false)

        _ = await executor.execute(
            FlowStep(action: "type", locator: FlowLocator(id: "wv_input"), text: "secret42"))
        let tapOutcome = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_send")))

        guard case .passed = tapOutcome.status else { return XCTFail("\(tapOutcome.status)") }
        XCTAssertEqual(driver.snapshotCallCount, 7,
                       "type解決(1)+最初の解決(1)+戻るまで(#3〜#5 の 3)+整定(2) = 7")
    }

    /// 改行で終わる type(Enter で閉じる)は、隠れても戻りを待たない
    func testTapAfterTypeEndingWithNewlineDoesNotWaitForTheKeyboard() async throws {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [
            [inputField(value: nil), sendButton(y: 480)],
            [inputField(value: nil), sendButton(y: 700)],
        ])
        driver.keyboardFrames = [shown, hidden]
        driver.verifiesTypedText = true
        let executor = StepExecutor(driver: driver, isAndroid: false)

        _ = await executor.execute(
            FlowStep(action: "type", locator: FlowLocator(id: "wv_input"), text: "abc\n"))
        let tapOutcome = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_send")))

        guard case .passed = tapOutcome.status else { return XCTFail("\(tapOutcome.status)") }
        XCTAssertEqual(driver.snapshotCallCount, 4,
                       "type解決(1)+最初の解決(1)+整定(2) = 4(戻りは待たない)")
    }
}
