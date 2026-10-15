// iOS の自動選定の入力(simctl の JSON)の読み取りと、選定結果に名前を添える部分。
// デバイス・Xcode を使わない(判定そのものは Tests/FTCoreTests/DevicePickerTests)。
import XCTest
import FTCore
@testable import fleetest

final class IOSAutoDeviceTests: XCTestCase {

    private let pro18 = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
    private let rt27 = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"

    func testParseRuntimesKeepsAvailableIOSAndReadsSupportedTypes() {
        let raw: [[String: Any]] = [
            ["identifier": rt27, "name": "iOS 27.0", "version": "27.0", "platform": "iOS", "isAvailable": true,
             "supportedDeviceTypes": [["identifier": pro18, "name": "iPhone 18 Pro"]]],
            ["identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-27-0", "name": "tvOS 27.0",
             "version": "27.0", "platform": "tvOS", "isAvailable": true],
            ["identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "name": "iOS 26.0",
             "version": "26.0", "platform": "iOS", "isAvailable": false],
        ]
        let runtimes = IOSRuntimeInstaller.parseRuntimes(raw)
        XCTAssertEqual(runtimes.map(\.identifier), [rt27])
        XCTAssertEqual(runtimes.first?.supportedDeviceTypeIdentifiers, [pro18])
    }

    func testMakeForInstalledRuntimeUsesTheRuntimeName() {
        let runtimes = [DevicePicker.IOSRuntimeInfo(
            identifier: rt27, version: "27.0", name: "iOS 27.0", supportedDeviceTypeIdentifiers: [pro18])]
        let device = IOSAutoDevice.make(
            target: .init(runtime: .installed(identifier: rt27), deviceTypeIdentifier: pro18),
            runtimes: runtimes, deviceTypes: [(identifier: pro18, name: "iPhone 18 Pro")])
        XCTAssertEqual(device, IOSAutoDevice(
            deviceTypeID: pro18, modelName: "iPhone 18 Pro", runtimeID: rt27,
            runtimeName: "iOS 27.0", runtimeVersion: "27.0", needsDownload: false))
    }

    /// 要ダウンロードは導入前なので runtime name を持たない: 命名は "iOS <版>"、identifier は予測値
    func testMakeForDownloadableRuntimeUsesPredictedIdentifierAndVersionLabel() {
        let device = IOSAutoDevice.make(
            target: .init(runtime: .needsDownload(version: "27.0"), deviceTypeIdentifier: pro18),
            runtimes: [], deviceTypes: [(identifier: pro18, name: "iPhone 18 Pro")])
        XCTAssertEqual(device?.runtimeID, rt27)
        XCTAssertEqual(device?.runtimeName, "iOS 27.0")
        XCTAssertEqual(device?.needsDownload, true)
        XCTAssertEqual(VirtualDeviceNaming.baseName(model: device?.modelName ?? "", osLabel: device?.runtimeName ?? ""),
                       "iPhone 18 Pro(iOS 27.0)")
    }

    func testMakeReturnsNilWhenTheModelNameIsUnknown() {
        XCTAssertNil(IOSAutoDevice.make(
            target: .init(runtime: .needsDownload(version: "27.0"), deviceTypeIdentifier: pro18),
            runtimes: [], deviceTypes: []))
    }

    /// 文言は実際に失敗した条件だけを言う(SDK が読めているのに「読めない」と言わない)
    func testUnresolvedReasonNamesTheSkippedModelSpecificRuntime() {
        let duo = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
        let iPhone17 = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
        let specific = DevicePicker.IOSRuntimeInfo(
            identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4", version: "27.2",
            name: "iOS 27.2", supportedDeviceTypeIdentifiers: [duo])
        let reason = IOSAutoDevice.unresolvedReason(
            runtimes: [specific], deviceTypeIdentifiers: [iPhone17, duo], sdkVersion: nil)
        XCTAssertTrue(reason.contains("no installed iOS runtime supports a plain iPhone <N> model"
            + " (skipped: com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4)"), reason)
        XCTAssertTrue(reason.contains("SDK version"), reason)
        XCTAssertEqual(
            IOSAutoDevice.unresolvedReason(runtimes: [], deviceTypeIdentifiers: [duo], sdkVersion: "27.2"),
            "no plain iPhone <N> device type is available in `xcrun simctl list devicetypes`")
        XCTAssertFalse(IOSAutoDevice.unresolvedReason(
            runtimes: [], deviceTypeIdentifiers: [iPhone17], sdkVersion: "27.2").contains("SDK"))
    }
}
