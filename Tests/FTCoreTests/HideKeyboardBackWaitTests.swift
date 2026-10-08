// type はキーボードの表示を待たずに返るので、ロケータを持たない操作(hideKeyboard / back)の前でも、直前の type の
// キーボードが出きるのを待つ(StepExecutor.consumePendingTypeKeyboardCheck)。
// - Android の hideKeyboard: まだ出ていないと「閉じるものが無い」で何もせずに返り、後から出たキーボードが次の back() を飲んだ
//   (E2EY-RN の Android の戻るの横取り S0040)
// - iOS の back(): XCUITest の /type は出る前に返り、上がってくる途中のキーボードの前に戻るが届いた(E2EY-iOS の XCUITest の S0040)
import XCTest
@testable import FTCore

final class HideKeyboardBackWaitTests: XCTestCase {

    private let field = ElementInfo(ref: 1, type: "textField", identifier: "field_title", label: nil, value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 16, y: 200, width: 300, height: 40), depth: 1)
    private let below = FTRect(x: 0, y: 891, width: 400, height: 233)
    private let shown = FTRect(x: 0, y: 560, width: 400, height: 240)

    private func typed(isAndroid: Bool, keyboardFrames: [FTRect?]) async -> (FakeAppDriver, StepExecutor, CallLog) {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log, snapshotElements: [[field]])
        driver.verifiesTypedText = true
        driver.keyboardFrames = keyboardFrames
        let executor = StepExecutor(driver: driver, isAndroid: isAndroid, tunables: RunTunables())
        _ = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "field_title"), text: "xyz"))
        return (driver, executor, log)
    }

    /// Android: hideKeyboard は、type のキーボードが出てから閉じに行く(出る前に見ると何もせずに返ってしまう)
    func testAndroidHideKeyboardWaitsForTheTypedKeyboardToAppearFirst() async {
        // type の解決(nil)→ hideKeyboard の前の読み(まだ無い ×2)→ 出る
        let (driver, executor, log) = await typed(isAndroid: true, keyboardFrames: [nil, nil, nil, shown])
        let before = driver.snapshotCallCount

        _ = await executor.execute(FlowStep(action: "hideKeyboard"))

        let hideIndex = try? XCTUnwrap(log.entries.lastIndex(of: "primary.hideKeyboard"))
        let snapshotsBeforeHide = log.entries[..<(hideIndex ?? 0)].filter { $0 == "primary.snapshot" }.count
        XCTAssertGreaterThanOrEqual(snapshotsBeforeHide - before, 3,
                                    "キーボードが出る(4 枚目)まで読み直してから閉じに行くはず: \(log.entries)")
    }

    /// iOS: back() の前に、type のキーボードが画面の外の申告から上がりきるのを待つ
    func testBackWaitsForTheKeyboardThatTypeIsStillBringingUp() async throws {
        // type の解決(nil)→ back の前の読み(画面の外 ×3)→ 上がる
        let (driver, executor, _) = await typed(isAndroid: false, keyboardFrames: [nil, below, below, below, shown])
        let before = driver.snapshotCallCount

        try await executor.awaitKeyboardBeforeBack()

        XCTAssertGreaterThanOrEqual(driver.snapshotCallCount - before, 4, "キーボードが画面に上がる(5 枚目)まで読み直すはず")
        let afterFirst = driver.snapshotCallCount
        try await executor.awaitKeyboardBeforeBack()
        XCTAssertEqual(driver.snapshotCallCount, afterFirst, "消化は1回だけ")
    }

    /// type していなければ何も読まない(back の費用を増やさない)
    func testNothingIsReadWithoutAPrecedingType() async throws {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        driver.keyboardFrames = [shown]
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())

        try await executor.awaitKeyboardBeforeBack()

        XCTAssertEqual(driver.snapshotCallCount, 0)
    }
}
