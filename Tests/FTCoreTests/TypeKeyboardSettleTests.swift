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
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())

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
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())

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
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())

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
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())

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
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())

        _ = await executor.execute(
            FlowStep(action: "type", locator: FlowLocator(id: "wv_input"), text: "abc\n"))
        let tapOutcome = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_send")))

        guard case .passed = tapOutcome.status else { return XCTFail("\(tapOutcome.status)") }
        XCTAssertEqual(driver.snapshotCallCount, 4,
                       "type解決(1)+最初の解決(1)+整定(2) = 4(戻りは待たない)")
    }

    // MARK: - Android: type の後のキーボードの出現待ち(KeyboardWait)
    // Android の type は IME の表示を待たずに返る(2026-10-05 実測: 要求から表示完了まで中央値 0.2 秒・最大 0.89 秒)。
    // 解決の木にまだ無いキーボードを、上限まで撮り直して待つ

    func testKeyboardWaitDefaultsArePinnedToLiterals() {
        XCTAssertEqual(KeyboardWait.appearSeconds, 1.5)
        XCTAssertEqual(KeyboardWait.pollSeconds, 0.15)
    }

    func testShouldAwaitAppearanceFlipsOnEachOfTheFourConditions() {
        func awaits(android: Bool = true, before: FTRect? = nil, after: FTRect? = nil,
                   newline: Bool = false) -> Bool {
            KeyboardWait.shouldAwaitAppearance(isAndroid: android, before: before, after: after,
                                               screen: screen, typedNewline: newline)
        }
        XCTAssertTrue(awaits())
        XCTAssertFalse(awaits(android: false), "iOS で申告が無い(nil)= そもそも出ない形は待たない")
        XCTAssertTrue(awaits(android: false, after: hidden),
                      "iOS でも画面の外の矩形で申告されたら出る直前 = 待つ(XCUITest の /type は出る前に返る)")
        XCTAssertFalse(awaits(android: false, after: shown), "iOS で既に出ていれば待たない")
        XCTAssertFalse(awaits(before: shown), "打つ前から出ているなら出現待ちではない")
        XCTAssertFalse(awaits(after: shown), "次の木に既に出ている")
        XCTAssertFalse(awaits(newline: true), "Enter で閉じうる")
        XCTAssertTrue(awaits(before: hidden, after: hidden), "画面外の矩形は「無い」扱い")
    }

    private func androidScript(isAndroid: Bool, keyboardFrames: [FTRect?],
                               typeText: String = "hello") async throws
        -> (count: Int, notes: Set<StepNote>, driver: FakeAppDriver, executor: StepExecutor) {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [
            [inputField(value: nil), sendButton(y: 700)],
            [inputField(value: nil), sendButton(y: 700)],
            [inputField(value: nil), sendButton(y: 700)],
            [inputField(value: nil), sendButton(y: 520)],
            [inputField(value: nil), sendButton(y: 480)],
        ])
        driver.keyboardFrames = keyboardFrames
        driver.verifiesTypedText = true
        let executor = StepExecutor(driver: driver, isAndroid: isAndroid, tunables: RunTunables())
        _ = await executor.execute(
            FlowStep(action: "type", locator: FlowLocator(id: "wv_input"), text: typeText))
        let outcome = await executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_send")))
        guard case .passed = outcome.status else {
            XCTFail("\(outcome.status)")
            return (driver.snapshotCallCount, [], driver, executor)
        }
        return (driver.snapshotCallCount, Set(outcome.notes), driver, executor)
    }

    /// ① 2枚目まで無く3枚目で出る → 撮り直して整定し、整定の注記が付く
    func testAndroidTapAfterTypeWaitsForTheKeyboardToAppearThenSettles() async throws {
        let result = try await androidScript(isAndroid: true, keyboardFrames: [nil, nil, shown])
        XCTAssertTrue(result.notes.contains(.settledAfterKeyboard), "出現後の整定へつながるはず")
        XCTAssertFalse(result.notes.contains(.keyboardNotShownAfterType))
        XCTAssertGreaterThanOrEqual(result.count, 6, "type解決(1)+最初の解決(1)+撮り直し(1)+整定(3)")
    }

    /// ①' iOS: 打った直後は画面の外(出る直前)と申告され、後から上がる → 待って整定してから押す
    /// (E2EY-Flutter の反転チャット: 待たずに下端の古い座標を押し、上がってきたキーボードに当たって送信が飲まれた)
    func testIOSTapAfterTypeWaitsWhileTheKeyboardIsReportedBelowTheScreen() async throws {
        let baseline = try await androidScript(isAndroid: false, keyboardFrames: [nil])
        let result = try await androidScript(isAndroid: false, keyboardFrames: [nil, hidden, hidden, shown])
        XCTAssertFalse(result.notes.contains(.keyboardNotShownAfterType), "上がったので尽きていない")
        XCTAssertGreaterThan(result.count, baseline.count,
                             "画面の外の申告の間は撮り直して待つ(申告が無い iOS = 待たない基準より多く撮る)")
    }

    /// ② 出ないまま → 上限で止まり注記。所要は壁時計(下限だけ厳しく、上限は負荷で落ちない緩さ)
    func testAndroidTapAfterTypeGivesUpAtTheCapAndNotes() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await androidScript(isAndroid: true, keyboardFrames: [nil])
        let elapsed = clock.now - started
        XCTAssertTrue(result.notes.contains(.keyboardNotShownAfterType))
        XCTAssertGreaterThan(elapsed, .milliseconds(1400), "上限(1.5 秒)まで待つはず")
        XCTAssertLessThan(elapsed, .seconds(10))
        XCTAssertTrue(result.executor.keyboardWaitExhausted, "待ち切った控えが残る")
    }

    /// ③ 待たない形(iOS / 打つ前から有り / 改行で終わる)は Android でも余分に撮らない
    func testNoExtraSnapshotsWhenTheWaitDoesNotApply() async throws {
        // iOS: キーボードは出ないまま。基準の撮影回数
        let ios = try await androidScript(isAndroid: false, keyboardFrames: [nil])
        XCTAssertFalse(ios.notes.contains(.keyboardNotShownAfterType))

        let newline = try await androidScript(isAndroid: true, keyboardFrames: [nil], typeText: "a\n")
        XCTAssertEqual(newline.count, ios.count, "改行で終わる type は待たない")
        XCTAssertFalse(newline.notes.contains(.keyboardNotShownAfterType))

        let before = try await androidScript(isAndroid: true, keyboardFrames: [shown, shown, shown, shown, shown])
        XCTAssertFalse(before.notes.contains(.keyboardNotShownAfterType), "打つ前から出ていれば出現待ちはしない")
        let iosBefore = try await androidScript(isAndroid: false,
                                                keyboardFrames: [shown, shown, shown, shown, shown])
        XCTAssertEqual(before.count, iosBefore.count)
    }

    /// ④ 待ち切った後のステップでキーボードが出ていた → keyboard-appeared-late、控えは消える
    func testKeyboardAppearedAfterTheWaitGaveUpIsNotedOnALaterStep() async throws {
        let result = try await androidScript(isAndroid: true, keyboardFrames: [nil])
        XCTAssertTrue(result.executor.keyboardWaitExhausted)
        result.driver.keyboardFrames = nil
        result.driver.keyboardFrame = shown
        let later = await result.executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_send")))
        XCTAssertTrue(later.notes.contains(.keyboardAppearedLate))
        XCTAssertFalse(result.executor.keyboardWaitExhausted, "観測したら控えを消す")
        let after = await result.executor.execute(
            FlowStep(action: "tap", locator: FlowLocator(id: "btn_send")))
        XCTAssertFalse(after.notes.contains(.keyboardAppearedLate), "1回だけ")
    }
}
