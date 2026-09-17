// M10b: 全掃討の拒否文言で、実機の Android は素の serial だけしか出ていなかった
// (シミュレータは「iPhone 17 Pro(iOS 27.0)-07 [UDID]」のように名前付き)。
// `adb devices -l` の model: 欄から serial → 機種名を作る純粋パーサの検証。

import XCTest
@testable import FTAndroid

final class AndroidDeviceCatalogModelParseTests: XCTestCase {

    func testParsesModelFromARealisticListing() {
        let output = """
        List of devices attached
        14141JEC204922         device usb:1-1 product:panther model:Pixel_7 device:panther transport_id:3
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1

        """
        let models = AndroidDeviceCatalog.parseDeviceModels(output: output)
        XCTAssertEqual(models["14141JEC204922"], "Pixel_7")
        XCTAssertEqual(models["emulator-5554"], "sdk_gphone64_arm64")
    }

    /// offline/unauthorized の行には model: が無いことが多い(state も "device" でない) —— 拾わない
    func testSkipsOfflineAndUnauthorizedLines() {
        let output = """
        List of devices attached
        ABCD1234        offline
        EFGH5678        unauthorized usb:1-1

        """
        XCTAssertEqual(AndroidDeviceCatalog.parseDeviceModels(output: output), [:])
    }

    func testEmptyOutputYieldsEmptyMap() {
        XCTAssertEqual(AndroidDeviceCatalog.parseDeviceModels(output: "List of devices attached\n\n"), [:])
    }
}
