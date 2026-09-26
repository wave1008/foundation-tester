// `bridge down --serial X`(--platform 省略)は platform の既定 "ios" のまま進み、serial を無視して
// iOS の既定ポートのブリッジ(別の台)を止めていた(破壊的操作)。`platform`/`port` を Optional にして
// 「明示されたか」を区別し、`--platform` 省略 + `--serial` だけのときは android と推定する
// (MCP の `platformName`/`foldInRememberedDevice` と同じ既定推定)。食い違いの判定は
// `FTCore.DeviceTargetConsistency`(MCP・DriverOptions と共有)。

import XCTest
import ArgumentParser
import FTCore
@testable import fleetest

final class BridgeDownTargetResolutionTests: XCTestCase {

    // MARK: - resolvedPlatform の既定推定(純粋。デバイス不要)

    func testSerialAloneResolvesToAndroid() throws {
        let down = try Bridge.Down.parse(["--serial", "emulator-5554"])
        XCTAssertEqual(down.resolvedPlatform, "android")
    }

    func testEverythingOmittedResolvesToIOS() throws {
        let down = try Bridge.Down.parse([])
        XCTAssertEqual(down.resolvedPlatform, "ios")
        XCTAssertEqual(down.resolvedPort, BridgeAPI.defaultPort)
    }

    func testPortAloneResolvesToIOS() throws {
        let down = try Bridge.Down.parse(["--port", "8200"])
        XCTAssertEqual(down.resolvedPlatform, "ios")
        XCTAssertEqual(down.resolvedPort, 8200)
    }

    /// 起こらないはずの組み合わせ(validate() が断る)だが、resolvedPlatform 自体は「明示があれば
    /// 必ずそれに従う」ことを固定する —— parse 後に直接フィールドを書き換えて validate() を経ずに検査する
    func testExplicitPlatformIsNotOverriddenBySerial() throws {
        var down = try Bridge.Down.parse(["--platform", "ios"])
        down.serial = "emulator-5554"
        XCTAssertEqual(down.resolvedPlatform, "ios")
    }

    // MARK: - validate() が断る組み合わせ

    func testPlatformIOSWithSerialIsRejected() {
        XCTAssertThrowsError(try Bridge.Down.parse(["--platform", "ios", "--serial", "emulator-5554"])) { error in
            let message = Bridge.Down.message(for: error)
            XCTAssertTrue(message.contains("--platform ios was given along with --serial"), message)
        }
    }

    func testPlatformAndroidWithPortIsRejected() {
        XCTAssertThrowsError(try Bridge.Down.parse(["--platform", "android", "--port", "8200"])) { error in
            let message = Bridge.Down.message(for: error)
            XCTAssertTrue(message.contains("--platform android was given along with an iOS target"), message)
        }
    }

    func testPortAndSerialWithNoPlatformIsRejected() {
        XCTAssertThrowsError(try Bridge.Down.parse(["--port", "8200", "--serial", "emulator-5554"])) { error in
            let message = Bridge.Down.message(for: error)
            XCTAssertTrue(message.contains("with no --platform to say which one to use"), message)
        }
    }

    /// `--all` は iOS 専用。android への推定/明示のどちらでも黙って無視しない
    func testAllWithSerialIsRejected() {
        XCTAssertThrowsError(try Bridge.Down.parse(["--all", "--serial", "emulator-5554"])) { error in
            let message = Bridge.Down.message(for: error)
            XCTAssertTrue(message.contains("--all is iOS-only"), message)
        }
    }

    func testAllWithExplicitPlatformAndroidIsRejected() {
        XCTAssertThrowsError(try Bridge.Down.parse(["--all", "--platform", "android"])) { error in
            let message = Bridge.Down.message(for: error)
            XCTAssertTrue(message.contains("--all is iOS-only"), message)
        }
    }

    // MARK: - 陰性対照

    func testAllWithoutAndroidTargetIsNotRejected() {
        XCTAssertNoThrow(try Bridge.Down.parse(["--all"]))
    }

    func testPlatformAndroidWithSerialIsNotRejected() {
        XCTAssertNoThrow(try Bridge.Down.parse(["--platform", "android", "--serial", "emulator-5554"]))
    }

    func testPlatformIOSWithPortIsNotRejected() {
        XCTAssertNoThrow(try Bridge.Down.parse(["--platform", "ios", "--port", "8200"]))
    }
}
