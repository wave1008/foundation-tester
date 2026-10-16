// api live serve の fold コマンド: state の読み取り・型違い・watchdog の猶予・文言。
// (実際の開閉の手順は FTCore.FoldControl のテストが持つ)

import FTCore
import XCTest

@testable import fleetest

final class ApiLiveFoldCommandTests: XCTestCase {
    private func command(_ raw: [String: Any]) -> ApiLiveServeCommand {
        var merged = raw
        merged["cmd"] = "fold"
        return ApiLiveServeCommand(cmd: "fold", raw: merged)
    }

    func testStateIsParsed() {
        let fold = command(["state": "fold"])
        XCTAssertNil(fold.decodeError)
        XCTAssertEqual(fold.state, "fold")
        XCTAssertEqual(command(["state": "unfold"]).state, "unfold")
        XCTAssertNil(command([:]).state, "省略は nil(perform が断る)")
    }

    func testNonStringStateIsATypeError() {
        let bad = command(["state": 1])
        guard let detail = bad.decodeError else { return XCTFail("数値の state が通った") }
        XCTAssertTrue(detail.contains("state must be a string"), detail)
        XCTAssertNil(bad.state)
    }

    func testFoldDrivesTheDevice() {
        XCTAssertTrue(command(["state": "fold"]).drivesDevice)
    }

    /// 猶予は既定の待ち(5秒)。観測ループの上限と同じ。窓の和には観測ぶん(session 45秒)が乗る
    func testWatchdogAllowanceIsTheDefaultWait() {
        XCTAssertEqual(command(["state": "fold"]).watchdogAllowanceSeconds, 5)
        XCTAssertEqual(command(["state": "fold"]).watchdogWindowAllowanceSeconds, 50)
        XCTAssertEqual(ApiLiveGestureDefaults.foldWaitSeconds, 5)
    }

    func testFailureMessages() {
        XCTAssertEqual(ApiLiveServe.foldFailureMessage(.notFoldable),
                       "This device is not foldable — fold/unfold works on the iPhone Duo simulator or a foldable"
                       + " Android Emulator. Nothing was sent.")
        XCTAssertEqual(ApiLiveServe.foldFailureMessage(.unreadable("boom")),
                       "Could not read whether the device is folded (boom), so nothing was sent.")
        XCTAssertEqual(
            ApiLiveServe.foldFailureMessage(.didNotSwitch(expected: .folded, observed: .state(.unfolded), waitedSeconds: 5)),
            "The device did not become folded within 5 s (it stayed unfolded).")
        XCTAssertTrue(ApiLiveServe.foldPhysicalRefusal.contains("physical device"))
    }
}
