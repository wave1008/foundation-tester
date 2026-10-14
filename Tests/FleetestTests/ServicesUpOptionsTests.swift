import FTCore
import XCTest
@testable import fleetest

/// run がサービスを起こすときの選択肢は、プロファイルの実機から導く(LAN 公開 = 実機があるとき・reverse = Android 実機だけ)。
final class ServicesUpOptionsTests: XCTestCase {
    func testRunOptionsFollowThePhysicalDevicesOfTheProfile() {
        let devices = [
            ResolvedDevice(platform: "ios", spec: DeviceSpec(name: "sim", kind: .virtual)),
            ResolvedDevice(platform: "android", spec: DeviceSpec(name: "pixel", kind: .physical, serial: "14141JEC204922")),
            ResolvedDevice(platform: "ios", spec: DeviceSpec(name: "se3", kind: .physical, udid: "00008110-0001")),
            ResolvedDevice(platform: "android", spec: DeviceSpec(name: "emu", kind: .virtual, avd: "Pixel_8")),
        ]
        let options = ServicesUpOptions.forRun(devices: devices)
        XCTAssertEqual(options.kind, .run)
        XCTAssertTrue(options.publishForPhysicalDevices)
        XCTAssertEqual(options.adbReverseSerials, ["14141JEC204922"], "iOS physical devices and emulators get no adb reverse")

        let virtualOnly = ServicesUpOptions.forRun(devices: [devices[0], devices[3]])
        XCTAssertFalse(virtualOnly.publishForPhysicalDevices)
        XCTAssertEqual(virtualOnly.adbReverseSerials, [])

        let iosPhysicalOnly = ServicesUpOptions.forRun(devices: [devices[2]])
        XCTAssertTrue(iosPhysicalOnly.publishForPhysicalDevices)
        XCTAssertEqual(iosPhysicalOnly.adbReverseSerials, [])
    }
}
