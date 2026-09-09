// `DriverOptions.skewMessage`(Fleetest.swift)は CLI 向けの版ズレ文言を組む純粋関数。
// 判定(どちらが新しいか)は `FTBridgeClient.BridgeVersionSkew` と共有するが、
// **対処の言い回しは CLI 専用**(`swift build --product fleetest` / `bridge down --port <port>`)——
// MCP(fleetest-mcp)の文言とは別に持つので、ここで固定する。

import XCTest
import FTBridgeClient
@testable import fleetest

final class DriverOptionsSkewMessageTests: XCTestCase {

    func testNewerBridgeTellsUserToRebuildOrPullTheCLI() {
        let message = DriverOptions.skewMessage(BridgeVersionSkew(running: 92, expected: 91), port: 8123)
        XCTAssertTrue(message.contains("NEWER than this build"), message)
        XCTAssertTrue(message.contains("swift build --product fleetest"), message)
        XCTAssertTrue(message.contains("v92"), message)
        XCTAssertTrue(message.contains("v91"), message)
        XCTAssertFalse(message.contains("bridge down"), message)
    }

    func testOlderBridgeTellsUserToRestartOnThatPort() {
        let message = DriverOptions.skewMessage(BridgeVersionSkew(running: 90, expected: 91), port: 8124)
        XCTAssertTrue(message.contains("OLDER than this build"), message)
        XCTAssertTrue(message.contains("fleetest bridge down --port 8124"), message)
        XCTAssertTrue(message.contains("fleetest bridge up"), message)
        XCTAssertFalse(message.contains("swift build"), message)
    }

    func testMessageNamesTheAllowFlag() {
        let message = DriverOptions.skewMessage(BridgeVersionSkew(running: 90, expected: 91), port: 8123)
        XCTAssertTrue(message.contains("--allow-version-skew"), message)
    }
}
