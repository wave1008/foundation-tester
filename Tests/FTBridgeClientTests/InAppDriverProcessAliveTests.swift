// crashAnnotated が .ips 無しのとき、殺された可能性だけを言わず生死を確かめる根拠になる純粋関数。
// 実測 2026-09-17: SIGSTOP でアプリを止めても .ips は出ず、プロセスは生きたまま無応答だった。

import XCTest
@testable import FTBridgeClient

final class InAppDriverProcessAliveTests: XCTestCase {

    func testRunningAppIsDetected() {
        let output = "12345\t0\tUIKitApplication:com.example.app[0x1234][rb-legacy]\n"
        XCTAssertTrue(InAppDriver.processIsRunning(inLaunchctlListOutput: output, bundleID: "com.example.app"))
    }

    /// PID 列が "-" は未起動を表す(生きているとは言わない)
    func testNotRunningAppShowsDashPID() {
        let output = "-\t0\tUIKitApplication:com.example.app[0x1234][rb-legacy]\n"
        XCTAssertFalse(InAppDriver.processIsRunning(inLaunchctlListOutput: output, bundleID: "com.example.app"))
    }

    func testBundleIDNotPresentAtAll() {
        let output = "12345\t0\tUIKitApplication:com.other.app[0x1234][rb-legacy]\n"
        XCTAssertFalse(InAppDriver.processIsRunning(inLaunchctlListOutput: output, bundleID: "com.example.app"))
    }

    /// ラベルの前方一致で別 bundle ID を拾わない("com.example.app2" は "com.example.app" とは別物)
    func testDoesNotPrefixMatchOtherBundleIDs() {
        let output = "12345\t0\tUIKitApplication:com.example.app2[0x1234][rb-legacy]\n"
        XCTAssertFalse(InAppDriver.processIsRunning(inLaunchctlListOutput: output, bundleID: "com.example.app"))
    }

    func testEmptyOutput() {
        XCTAssertFalse(InAppDriver.processIsRunning(inLaunchctlListOutput: "", bundleID: "com.example.app"))
    }
}
