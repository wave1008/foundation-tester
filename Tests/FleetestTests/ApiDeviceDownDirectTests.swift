// stop-device の --name/--udid/--serial 直指定モード(未登録デバイス向け)。
// ApiDeviceDownDirectTarget.resolve(検証)・ApiDeviceDownDirectSpec(spec 合成)はどちらも
// I/O を持たない pure 関数なので、ここではカタログ・シミュレータ無しで判定ロジックだけを検証する。

import XCTest
import FTBridgeClient
import FTCore
@testable import fleetest

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
        XCTAssertEqual(
            ApiDeviceDownDirectSpec.iosSpec(udid: "ABCD-1234", simCatalog: catalog,
                                            physicalDevices: []),
            .success(DeviceSpec(name: "iPhone 17 Pro", udid: "ABCD-1234")))
    }

    func testIosSpecFallsBackToUdidWhenUnresolvable() {
        XCTAssertEqual(
            ApiDeviceDownDirectSpec.iosSpec(udid: "ABCD-1234", simCatalog: [], physicalDevices: []),
            .success(DeviceSpec(name: "ABCD-1234", udid: "ABCD-1234")))
    }

    /// **実機の UDID を渡されたら、そう名指しして断る** —— 通すと simctl が
    /// 「no simulator with that UDID」と言い、渡したものが実機だったことを誰も言わない
    func testIosSpecNamesThePhysicalDeviceWhenTheUdidIsOne() {
        let physical = [IOSPhysicalDeviceInfo(
            udid: "00008110-000260242EEB801E", name: "iPhone SE3", os: "iOS 26.6",
            connected: true, transport: "wired", deviceCtlIdentifier: nil)]
        guard case .failure(let message) = ApiDeviceDownDirectSpec.iosSpec(
            udid: "00008110-000260242EEB801E", simCatalog: [], physicalDevices: physical) else {
            return XCTFail("実機の UDID は断るべき")
        }
        XCTAssertTrue(message.contains("is a connected physical device"), message)
        XCTAssertTrue(message.contains("iPhone SE3"), message)
    }

    // MARK: - ApiDeviceDownDirectSpec.androidSpec

    func testAndroidSpecResolvesAvdIdFromSerial() throws {
        let result = ApiDeviceDownDirectSpec.androidSpec(
            serial: "emulator-5554", runningAVDs: ["emulator-5554": "Pixel_9_Android_15_-01"],
            connectedSerials: ["emulator-5554"])
        switch result {
        case .success(let spec):
            XCTAssertEqual(spec.name, "Pixel_9_Android_15_-01")
            XCTAssertEqual(spec.avd, "Pixel_9_Android_15_-01")
        case .failure(let message):
            XCTFail("expected success, got failure: \(message)")
        }
    }

    func testAndroidSpecFailsWhenSerialNotFound() {
        let result = ApiDeviceDownDirectSpec.androidSpec(
            serial: "emulator-9999", runningAVDs: [:], connectedSerials: [])
        switch result {
        case .success:
            XCTFail("expected failure")
        case .failure(let message):
            XCTAssertTrue(message.contains("emulator-9999"))
        }
    }

    /// 実機(AVD を持たない)は runningAVDs に居ないので、接続一覧から解決する。
    /// **kind が physical でないと DeviceBooter.shutdownOne がエミュレータ扱いで
    /// `adb emu kill` を撃つ** —— 利用者の端末を落とすので、ここは名前ではなく kind で固定する
    func testAndroidSpecResolvesConnectedPhysicalDeviceAsPhysical() {
        let result = ApiDeviceDownDirectSpec.androidSpec(
            serial: "93MAY0CY1M", runningAVDs: [:], connectedSerials: ["93MAY0CY1M"])
        switch result {
        case .success(let spec):
            XCTAssertTrue(spec.isPhysical, "実機を physical に解決しないと adb emu kill が飛ぶ")
            XCTAssertEqual(spec.serial, "93MAY0CY1M")
            XCTAssertNil(spec.avd, "実機に AVD を持たせない")
        case .failure(let message):
            XCTFail("expected success, got failure: \(message)")
        }
    }

    /// エミュレータは physical にしない(こちらは端末ごと停止してよい)
    func testAndroidSpecKeepsEmulatorsNonPhysical() {
        let result = ApiDeviceDownDirectSpec.androidSpec(
            serial: "emulator-5554", runningAVDs: ["emulator-5554": "AVD-1"],
            connectedSerials: ["emulator-5554"])
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertFalse(spec.isPhysical)
    }
}
