// device-wipe の識別子直指定(delete-device と同じ契約: プロジェクト・マシンプロファイルを
// 一切参照しない)。ApiDeviceWipeTarget は I/O を持たない pure 関数なので、ここでは
// 検証と spec 合成だけを見る(実際の削除・停止・再起動は DeviceWiper 側)。

import XCTest
import FTBridgeClient
import FTAndroid
import FTCore
@testable import fleetest

final class ApiDeviceWipeTargetTests: XCTestCase {

    // MARK: - resolve(引数の検証)

    func testResolveAcceptsIOSUdid() throws {
        XCTAssertEqual(try ApiDeviceWipeTarget.resolve(platform: "ios", udid: "ABCD-1234", avd: nil),
                       .ios(udid: "ABCD-1234"))
    }

    func testResolveAcceptsAndroidAVD() throws {
        XCTAssertEqual(try ApiDeviceWipeTarget.resolve(platform: "android", udid: nil, avd: "Pixel_8"),
                       .android(avd: "Pixel_8"))
    }

    /// **識別子が無いまま進めない** —— 進めると「何も消さずに成功」か、別の台を消すかのどちらかになる
    func testResolveThrowsWhenTheIdentifierIsMissingOrEmpty() {
        XCTAssertThrowsError(try ApiDeviceWipeTarget.resolve(platform: "ios", udid: nil, avd: nil))
        XCTAssertThrowsError(try ApiDeviceWipeTarget.resolve(platform: "android", udid: nil, avd: nil))
        XCTAssertThrowsError(try ApiDeviceWipeTarget.resolve(platform: "ios", udid: "", avd: nil))
        XCTAssertThrowsError(try ApiDeviceWipeTarget.resolve(platform: "android", udid: nil, avd: ""))
    }

    /// platform と識別子の取り違えは黙って通さない(iOS に --avd を渡すと Android の台を指しかねない)
    func testResolveThrowsWhenTheIdentifierBelongsToTheOtherPlatform() {
        XCTAssertThrowsError(try ApiDeviceWipeTarget.resolve(platform: "ios", udid: nil, avd: "Pixel_8"))
        XCTAssertThrowsError(try ApiDeviceWipeTarget.resolve(platform: "android", udid: "ABCD-1234", avd: nil))
    }

    func testResolveThrowsOnUnknownPlatform() {
        XCTAssertThrowsError(try ApiDeviceWipeTarget.resolve(platform: "web", udid: "ABCD-1234", avd: nil))
    }

    // MARK: - spec(表示名の合成)

    func testIOSSpecUsesTheSimulatorNameWhenTheCatalogKnowsIt() {
        let catalog = [SimDeviceInfo(udid: "ABCD-1234", name: "iPhone 17 Pro", os: "iOS 27.0", booted: true)]
        let spec = ApiDeviceWipeTarget.ios(udid: "ABCD-1234").spec(simCatalog: catalog)
        XCTAssertEqual(spec.name, "iPhone 17 Pro")
        XCTAssertEqual(spec.udid, "ABCD-1234")
        XCTAssertFalse(spec.isPhysical, "識別子から作る spec は必ず仮想デバイス")
    }

    func testIOSSpecFallsBackToTheUdidWhenTheCatalogDoesNotKnowIt() {
        let spec = ApiDeviceWipeTarget.ios(udid: "ABCD-1234").spec(simCatalog: [])
        XCTAssertEqual(spec.name, "ABCD-1234")
        XCTAssertEqual(spec.udid, "ABCD-1234")
    }

    func testAndroidSpecCarriesTheAVD() {
        let spec = ApiDeviceWipeTarget.android(avd: "Pixel_8").spec(simCatalog: [])
        XCTAssertEqual(spec.avd, "Pixel_8")
        XCTAssertEqual(spec.name, "Pixel_8")
        XCTAssertFalse(spec.isPhysical)
    }

    /// spec がそのまま DeviceWiper の振り分けを通ること(表示名だけの型にしない)
    func testSpecsRouteToTheMatchingWiperTarget() throws {
        let ios = ApiDeviceWipeTarget.ios(udid: "ABCD-1234").spec(simCatalog: [])
        XCTAssertEqual(try DeviceWiper.target(spec: ios, platform: "ios"), .ios)
        let android = ApiDeviceWipeTarget.android(avd: "Pixel_8").spec(simCatalog: [])
        XCTAssertEqual(try DeviceWiper.target(spec: android, platform: "android"), .android(avd: "Pixel_8"))
    }
}
