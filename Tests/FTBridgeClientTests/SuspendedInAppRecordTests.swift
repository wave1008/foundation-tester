// 答えないポートを「背面で止まった in-app ブリッジ」と読む条件。読めないと、起動し直した MCP の ft_launch が
// 答えない XCUITest として扱って待った末に断る。読み過ぎると、止まったシミュレータの残骸や同名の別の機へ注入する

import XCTest
@testable import FTBridgeClient

final class SuspendedInAppRecordTests: XCTestCase {

    private let record = (udid: "AAAA-1", bundleID: "com.example.app")

    func testRecordOnABootedSimulatorIsReadAsSuspendedInApp() throws {
        let found = try XCTUnwrap(ExploreDriverResolver.suspendedInAppRecord(
            record: record, bootedSimulators: [(udid: "AAAA-1", name: "iPhone-01"), (udid: "BBBB-2", name: "iPhone-02")]))
        XCTAssertEqual(found.udid, "AAAA-1")
        XCTAssertEqual(found.bundleID, "com.example.app")
        XCTAssertEqual(found.name, "iPhone-01")
    }

    func testNoRecordOrShutDownSimulatorIsNotSuspendedInApp() {
        XCTAssertNil(ExploreDriverResolver.suspendedInAppRecord(
            record: nil, bootedSimulators: [(udid: "AAAA-1", name: "iPhone-01")]))
        XCTAssertNil(ExploreDriverResolver.suspendedInAppRecord(
            record: record, bootedSimulators: [(udid: "BBBB-2", name: "iPhone-02")]), "台帳のシミュレータが起動していない = 残骸")
    }

    /// XCUITest の相方はデバイス名で探すので、同名2台では別の機の相方を掴む
    func testDuplicateNameIsNotTrusted() {
        XCTAssertNil(ExploreDriverResolver.suspendedInAppRecord(
            record: record, bootedSimulators: [(udid: "AAAA-1", name: "iPhone"), (udid: "BBBB-2", name: "iPhone")]))
    }
}
