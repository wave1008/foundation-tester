// 手動 Wipe Data(fleetest api device-wipe)の**振り分けだけ**を検証する。
// 実際の削除・停止・再起動はデバイスに触るのでここでは対象外
// (Android の対象ファイル列挙は AndroidDataWiperTests)。
// ここが守るのは「消せないものを途中まで進めない」—— 実機・avd 未設定・未知の platform は
// **停止する前に**弾く。

import XCTest
import FTCore
@testable import FTAndroid

final class DeviceWiperTests: XCTestCase {

    func testIOSSimulatorGoesToTheErasePath() throws {
        let spec = DeviceSpec(name: "シミュ1", udid: "UDID-1")
        XCTAssertEqual(try DeviceWiper.target(spec: spec, platform: "ios"), .ios)
    }

    func testAndroidEmulatorCarriesItsAVD() throws {
        let spec = DeviceSpec(name: "エミュ1", avd: "Pixel_8")
        XCTAssertEqual(try DeviceWiper.target(spec: spec, platform: "android"), .android(avd: "Pixel_8"))
    }

    func testPhysicalDeviceIsRejectedOnBothPlatforms() {
        for platform in ["ios", "android"] {
            let spec = DeviceSpec(name: "実機1", kind: .physical, udid: "UDID-P", avd: "Pixel_8")
            XCTAssertThrowsError(try DeviceWiper.target(spec: spec, platform: platform)) { error in
                XCTAssertEqual(error as? DeviceWiperError, .physicalDevice(name: "実機1"))
            }
        }
    }

    func testAndroidWithoutAVDIsRejected() {
        let spec = DeviceSpec(name: "エミュ1")
        XCTAssertThrowsError(try DeviceWiper.target(spec: spec, platform: "android")) { error in
            XCTAssertEqual(error as? DeviceWiperError, .noAVD(name: "エミュ1"))
        }
    }

    func testUnknownPlatformIsRejected() {
        let spec = DeviceSpec(name: "なにか", avd: "Pixel_8")
        XCTAssertThrowsError(try DeviceWiper.target(spec: spec, platform: "web")) { error in
            XCTAssertEqual(error as? DeviceWiperError, .unsupportedPlatform("web"))
        }
    }
}
