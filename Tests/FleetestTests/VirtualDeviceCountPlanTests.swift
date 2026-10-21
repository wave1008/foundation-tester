// `profile setup --auto-device --count N` の振り分け(再利用 / 新規 / 何もしない)と、
// create-device の同名拒否文。simctl / avdmanager は呼ばない純粋部分だけ。

import XCTest
@testable import fleetest
@testable import FTCore

final class VirtualDeviceCountPlanTests: XCTestCase {

    private let base = "Pixel 10(Android 16, API 36, APIs)"
    private func n(_ number: Int) -> String { "\(base)-\(number < 10 ? "0" : "")\(number)" }

    func testReusesMatchingDevicesFromLowestNumberThenCreates() {
        let plan = VirtualDeviceFactory.countPlan(
            base: base, existing: [n(3), n(1), n(2)], registered: [], total: 4,
            isReusable: { $0 != self.n(2) })
        XCTAssertEqual(plan.reuse, [n(1), n(3)])
        // -02 は中身が違うが名前は使用中 = 新規は -04 から
        XCTAssertEqual(plan.create, [n(4), n(5)])
        XCTAssertEqual(plan.shortfall, 0)
    }

    func testRegisteredDevicesAreCountedAndNotReusedAgain() {
        let plan = VirtualDeviceFactory.countPlan(
            base: base, existing: [n(1), n(2)], registered: [n(1)], total: 2, isReusable: { _ in true })
        XCTAssertEqual(plan.reuse, [n(2)])
        XCTAssertEqual(plan.create, [])
    }

    func testRegisteredUnrelatedDeviceStillCountsTowardTotal() {
        let plan = VirtualDeviceFactory.countPlan(
            base: base, existing: [n(1)], registered: ["Pixel 9 (physical)"], total: 2, isReusable: { _ in true })
        XCTAssertEqual(plan.reuse, [n(1)])
        XCTAssertTrue(plan.create.isEmpty)
    }

    func testNothingToAddWhenAlreadyAtOrAboveTotal() {
        for registered in [2, 3] {
            let plan = VirtualDeviceFactory.countPlan(
                base: base, existing: [n(1), n(2), n(3)], registered: (1...registered).map(n), total: 2,
                isReusable: { _ in true })
            XCTAssertTrue(plan.isSatisfied, "registered=\(registered)")
        }
    }

    func testCreatedNamesAvoidEveryExistingNameOnTheMachine() {
        let plan = VirtualDeviceFactory.countPlan(
            base: base, existing: [n(1), n(2), n(4)], registered: [], total: 3, isReusable: { _ in false })
        XCTAssertEqual(plan.create, [n(3), n(5), n(6)])
    }

    func testDuplicateNamesAreReusedOnce() {
        let plan = VirtualDeviceFactory.countPlan(
            base: base, existing: [n(1), n(1), n(1)], registered: [], total: 2, isReusable: { _ in true })
        XCTAssertEqual(plan.reuse, [n(1)])
        XCTAssertEqual(plan.create, [n(2)])
    }

    func testShortfallWhenSerialNumbersAreExhausted() {
        let all = (1...99).map(n)
        let plan = VirtualDeviceFactory.countPlan(
            base: base, existing: all, registered: [], total: 2, isReusable: { _ in false })
        XCTAssertEqual(plan.shortfall, 2)
        XCTAssertFalse(plan.isSatisfied)
    }

    // MARK: - 同名拒否

    func testSameNameRefusalIsNilWhenNothingExists() {
        XCTAssertNil(VirtualDeviceFactory.sameNameRefusal(platform: "ios", name: "x", existing: []))
    }

    func testSameNameRefusalNamesTheExistingDeviceAndTheWaysOut() throws {
        let ios = try XCTUnwrap(VirtualDeviceFactory.sameNameRefusal(
            platform: "ios", name: "iPhone 17(iOS 27.2)-02", existing: ["UDID AAA", "UDID BBB"]))
        XCTAssertTrue(ios.contains("UDID AAA") && ios.contains("UDID BBB"))
        XCTAssertTrue(ios.contains("--device-name") && ios.contains("--overwrite"))
        let android = try XCTUnwrap(VirtualDeviceFactory.sameNameRefusal(
            platform: "android", name: "P-02", existing: ["AVD id P_02"]))
        XCTAssertTrue(android.contains("AVD id P_02") && android.contains("--avd") && android.contains("--overwrite"))
    }

    func testLocalDeviceNamesByPlatform() {
        let object: [String: Any] = ["devices": [
            ["platform": "ios", "machine": "local", "name": "a"],
            ["platform": "android", "machine": "local", "name": "b"],
            ["platform": "ios", "machine": "Remote1", "name": "c"],
        ]]
        XCTAssertEqual(RunProfileDeviceEditor.localDeviceNames(inRunProfileObject: object, platform: "ios"), ["a"])
    }
}
