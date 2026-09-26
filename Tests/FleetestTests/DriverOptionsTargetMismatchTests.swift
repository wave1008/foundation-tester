// platform と宛先(--port/--serial・api live serve の --udid)の食い違いは parse 時点(validate())
// で断る。実測: `fleetest api list-apps --platform ios --serial X` は --serial を黙って捨てて既定の
// iOS ブリッジの台を返していた。判定は FTCore.DeviceTargetConsistency(MCP と共有)、
// この OptionGroup(DriverOptions)を持つ各コマンドが自分の validate() から呼ぶ
// (ArgumentParser は OptionGroup の validate() を自動では呼ばない)。

import XCTest
import ArgumentParser
@testable import fleetest

final class DriverOptionsTargetMismatchTests: XCTestCase {

    // MARK: - 拒否すべき組み合わせ(複数コマンドを代表として当てる)

    func testTapRejectsSerialWithPlatformIOS() {
        XCTAssertThrowsError(try Tap.parse(["--platform", "ios", "--serial", "emulator-5554"])) { error in
            let message = Tap.message(for: error)
            XCTAssertTrue(message.contains("--platform ios was given along with --serial"), message)
        }
    }

    func testTapRejectsPortWithPlatformAndroid() {
        XCTAssertThrowsError(try Tap.parse(["--platform", "android", "--port", "8200"])) { error in
            let message = Tap.message(for: error)
            XCTAssertTrue(message.contains("--platform android was given along with an iOS target"), message)
        }
    }

    func testTapRejectsPortAndSerialWithNoPlatform() {
        XCTAssertThrowsError(try Tap.parse(["--port", "8200", "--serial", "emulator-5554"])) { error in
            let message = Tap.message(for: error)
            XCTAssertTrue(message.contains("with no --platform to say which one to use"), message)
        }
    }

    /// 実測した事故そのもの: `api list-apps --platform ios --serial X` が serial を黙って捨てていた
    func testApiListAppsRejectsSerialWithPlatformIOS() {
        XCTAssertThrowsError(try ApiListApps.parse(["--platform", "ios", "--serial", "emulator-5554"])) { error in
            let message = ApiListApps.message(for: error)
            XCTAssertTrue(message.contains("--platform ios was given along with --serial"), message)
        }
    }

    func testBridgeUpRejectsSerialWithPlatformIOS() {
        XCTAssertThrowsError(try Bridge.Up.parse(["--platform", "ios", "--serial", "emulator-5554"])) { error in
            let message = Bridge.Up.message(for: error)
            XCTAssertTrue(message.contains("--platform ios was given along with --serial"), message)
        }
    }

    func testBridgeStatusRejectsPortAndSerialWithNoPlatform() {
        XCTAssertThrowsError(try Bridge.Status.parse(["--port", "8200", "--serial", "emulator-5554"])) { error in
            let message = Bridge.Status.message(for: error)
            XCTAssertTrue(message.contains("with no --platform to say which one to use"), message)
        }
    }

    /// api live serve は udid を DriverOptions と別に持つので、extraIOSTarget 経由で同じ判定に掛かる
    func testApiLiveServeRejectsUDIDWithPlatformAndroid() {
        XCTAssertThrowsError(
            try ApiLiveServe.parse(["--platform", "android", "--udid", "257324AF-0000"])
        ) { error in
            let message = ApiLiveServe.message(for: error)
            XCTAssertTrue(message.contains("--platform android was given along with an iOS target"), message)
        }
    }

    func testApiLiveServeRejectsUDIDWithSerialAndNoPlatform() {
        XCTAssertThrowsError(
            try ApiLiveServe.parse(["--udid", "257324AF-0000", "--serial", "emulator-5554"])
        ) { error in
            let message = ApiLiveServe.message(for: error)
            XCTAssertTrue(message.contains("with no --platform to say which one to use"), message)
        }
    }

    // MARK: - 陰性対照: 断ってはいけない組み合わせ

    func testTapAllowsSerialAlone() {
        XCTAssertNoThrow(try Tap.parse(["--serial", "emulator-5554"]))
    }

    func testTapAllowsPlatformAndroidWithSerial() {
        XCTAssertNoThrow(try Tap.parse(["--platform", "android", "--serial", "emulator-5554"]))
    }

    func testTapAllowsPlatformIOSWithPort() {
        XCTAssertNoThrow(try Tap.parse(["--platform", "ios", "--port", "8200"]))
    }

    func testTapAllowsEverythingOmitted() {
        XCTAssertNoThrow(try Tap.parse([]))
    }

    func testApiLiveServeAllowsUDIDAlone() {
        XCTAssertNoThrow(try ApiLiveServe.parse(["--udid", "257324AF-0000"]))
    }

    /// udid と port は両方 iOS の宛先なので、platform ios と併用しても食い違いではない
    func testApiLiveServeAllowsPlatformIOSWithUDIDAndPort() {
        XCTAssertNoThrow(try ApiLiveServe.parse(
            ["--platform", "ios", "--udid", "257324AF-0000", "--port", "8200"]))
    }

    /// `--serial` だけなら android へ解決する(ios に倒すと既定ポートの別の台を操作する)
    func testSerialAloneResolvesToAndroid() throws {
        XCTAssertEqual(try ApiListApps.parse(["--serial", "emulator-5554"]).driverOptions.resolvedPlatform, "android")
        XCTAssertEqual(try Tap.parse(["--serial", "emulator-5554", "--ref", "1"]).driverOptions.resolvedPlatform, "android")
        XCTAssertEqual(try ApiListApps.parse([]).driverOptions.resolvedPlatform, "ios")
    }
}
