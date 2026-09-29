// 契約: `XCUIBridgeResolver.freePort` は in-app の台帳(`.inapp`)が残るポートを後回しにする。
// in-app ブリッジはアプリの起こし直しの間だけ待受が消えるので、稼働中の走査と `.pid` だけを見ると
// run のレーンのポートを空きと読む(ライブ操作の自動起動がそこへ別のデバイスのランナーを建てた)。

import Foundation
import XCTest
@testable import FTBridgeClient

final class FreePortInAppLedgerTests: XCTestCase {

    private var repoRoot: URL!
    private var stateDir: URL { repoRoot.appendingPathComponent(".fleetest") }

    override func setUpWithError() throws {
        repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeport-inapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    private func writeInApp(port: UInt16) {
        InAppBridgeState.write(stateDir: stateDir, port: port, udid: "UDID-OF-A-RUN-LANE",
                               bundleID: "com.example.app", sourceDigest: nil)
    }

    func testPortWithAnInAppLedgerIsSkipped() {
        writeInApp(port: 8123)
        XCTAssertEqual(XCUIBridgeResolver.freePort(repoRoot: repoRoot, occupied: []), 8124)
    }

    func testSeveralLedgersAndOccupiedPortsAreAllSkipped() {
        writeInApp(port: 8123)
        writeInApp(port: 8125)
        XCTAssertEqual(XCUIBridgeResolver.freePort(repoRoot: repoRoot, occupied: [8124]), 8126)
    }

    /// 逆向き: 台帳が無ければ今までどおり先頭を採る
    func testFirstPortIsPickedWhenNothingIsRecorded() {
        XCTAssertEqual(XCUIBridgeResolver.freePort(repoRoot: repoRoot, occupied: []), 8123)
    }

    /// 台帳は予約ではない: 範囲の全部に残っていたら、残っているポートから採る(枯渇させない)
    func testLedgerIsNotAReservationWhenEveryPortHasOne() {
        for port in UInt16(8123)...UInt16(8154) { writeInApp(port: port) }
        XCTAssertEqual(XCUIBridgeResolver.freePort(repoRoot: repoRoot, occupied: [8123]), 8124)
    }

    // MARK: - 台帳から「別のデバイスのポート」と言えるか

    func testLedgerOfAnotherDeviceIsRecognized() {
        writeInApp(port: 8123)
        XCTAssertTrue(InAppBridgeState.isRecordedForAnotherDevice(
            stateDir: stateDir, port: 8123, udid: "SOME-OTHER-DEVICE"))
    }

    /// 逆向き: 自分の台帳・台帳なしは「別のデバイス」と言わない(大文字小文字の違いは同じデバイス)
    func testOwnLedgerAndMissingLedgerAreNotAnotherDevice() {
        writeInApp(port: 8123)
        XCTAssertFalse(InAppBridgeState.isRecordedForAnotherDevice(
            stateDir: stateDir, port: 8123, udid: "udid-of-a-run-lane"))
        XCTAssertFalse(InAppBridgeState.isRecordedForAnotherDevice(
            stateDir: stateDir, port: 8124, udid: "SOME-OTHER-DEVICE"))
    }
}
