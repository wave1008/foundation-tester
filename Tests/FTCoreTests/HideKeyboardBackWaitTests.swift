// Android の hideKeyboard の後、ロケータを持たない back() の前でもキーボードが木から消えるまで待つ
// (StepExecutor.awaitPendingHideKeyboard)。待たずに戻るキーを送ると、閉じきる前の IME に吸われて画面が戻らない
// (E2EY-RN の戻るの横取り S0040 が、高負荷のスイートでだけ「back が効いていない」で赤)
import XCTest
@testable import FTCore

final class HideKeyboardBackWaitTests: XCTestCase {

    private let keyboard = FTRect(x: 0, y: 500, width: 400, height: 300)

    func testBackWaitsUntilTheKeyboardLeavesTheTreeAfterHideKeyboard() async throws {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        driver.keyboardFrames = [keyboard, keyboard, keyboard, nil]
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        _ = await executor.execute(FlowStep(action: "hideKeyboard"))
        let before = driver.snapshotCallCount

        try await executor.awaitPendingHideKeyboard()

        XCTAssertGreaterThanOrEqual(driver.snapshotCallCount - before, 4,
                                    "キーボードが木から消える(4 枚目)まで読み直すはず")
        // 消化は1回だけ(2回目の back は何も読まない)
        let afterFirst = driver.snapshotCallCount
        try await executor.awaitPendingHideKeyboard()
        XCTAssertEqual(driver.snapshotCallCount, afterFirst)
    }

    /// hideKeyboard していなければ何も読まない(back の費用を増やさない)
    func testNothingIsReadWithoutAPrecedingHideKeyboard() async throws {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        driver.keyboardFrames = [keyboard]
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())

        try await executor.awaitPendingHideKeyboard()

        XCTAssertEqual(driver.snapshotCallCount, 0)
    }
}
