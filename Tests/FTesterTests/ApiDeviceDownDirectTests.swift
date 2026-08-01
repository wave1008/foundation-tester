// device-down の --name/--udid/--serial 直指定モード(未登録デバイス向け)。
// ApiDeviceDownDirectTarget.resolve(検証)・ApiDeviceDownDirectSpec(spec 合成)はどちらも
// I/O を持たない pure 関数なので、ここではカタログ・シミュレータ無しで判定ロジックだけを検証する。

import XCTest
import FTBridgeClient
import FTCore
@testable import ftester

final class ApiDeviceDownDirectTests: XCTestCase {

    // MARK: - ApiDeviceDownDirectTarget.resolve

    func testResolveAcceptsNameOnly() throws {
        let target = try ApiDeviceDownDirectTarget.resolve(name: "sim1", udid: nil, serial: nil)
        XCTAssertEqual(target, .name("sim1"))
    }

    func testResolveAcceptsUdidOnly() throws {
        let target = try ApiDeviceDownDirectTarget.resolve(name: nil, udid: "ABCD-1234", serial: nil)
        XCTAssertEqual(target, .udid("ABCD-1234"))
    }

    func testResolveAcceptsSerialOnly() throws {
        let target = try ApiDeviceDownDirectTarget.resolve(name: nil, udid: nil, serial: "emulator-5554")
        XCTAssertEqual(target, .serial("emulator-5554"))
    }

    func testResolveThrowsWhenNoneGiven() {
        XCTAssertThrowsError(try ApiDeviceDownDirectTarget.resolve(name: nil, udid: nil, serial: nil))
    }

    func testResolveThrowsWhenTwoGiven() {
        XCTAssertThrowsError(
            try ApiDeviceDownDirectTarget.resolve(name: "sim1", udid: "ABCD-1234", serial: nil))
    }

    func testResolveThrowsWhenAllThreeGiven() {
        XCTAssertThrowsError(
            try ApiDeviceDownDirectTarget.resolve(name: "sim1", udid: "ABCD-1234", serial: "emulator-5554"))
    }

    // MARK: - ApiDeviceDownDirectSpec.iosSpec

    func testIosSpecUsesSimulatorNameWhenResolvable() {
        let catalog = [SimDeviceInfo(udid: "ABCD-1234", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)]
        let spec = ApiDeviceDownDirectSpec.iosSpec(udid: "ABCD-1234", simCatalog: catalog)
        XCTAssertEqual(spec.name, "iPhone 17 Pro")
        XCTAssertEqual(spec.udid, "ABCD-1234")
    }

    func testIosSpecFallsBackToUdidWhenUnresolvable() {
        let spec = ApiDeviceDownDirectSpec.iosSpec(udid: "ABCD-1234", simCatalog: [])
        XCTAssertEqual(spec.name, "ABCD-1234")
        XCTAssertEqual(spec.udid, "ABCD-1234")
    }

    // MARK: - ApiDeviceDownDirectSpec.androidSpec

    func testAndroidSpecResolvesAvdIdFromSerial() throws {
        let result = ApiDeviceDownDirectSpec.androidSpec(
            serial: "emulator-5554", runningAVDs: ["emulator-5554": "Pixel_9_Android_15_-01"])
        switch result {
        case .success(let spec):
            XCTAssertEqual(spec.name, "Pixel_9_Android_15_-01")
            XCTAssertEqual(spec.avd, "Pixel_9_Android_15_-01")
        case .failure(let message):
            XCTFail("expected success, got failure: \(message)")
        }
    }

    func testAndroidSpecFailsWhenSerialNotFound() {
        let result = ApiDeviceDownDirectSpec.androidSpec(serial: "emulator-9999", runningAVDs: [:])
        switch result {
        case .success:
            XCTFail("expected failure")
        case .failure(let message):
            XCTAssertTrue(message.contains("emulator-9999"))
        }
    }
}
