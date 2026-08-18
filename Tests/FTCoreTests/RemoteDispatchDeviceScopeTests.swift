// ホスト混在プロファイルを --host で単一ホストへ丸ごと送らないための絞り込み判定を固定する。
// 丸ごと送ると受け側の「local」枠が発行元のデバイスに解決される(2026-08-18 実害)。

import XCTest
@testable import FTCore

final class RemoteDispatchDeviceScopeTests: XCTestCase {
    func testAllDevicesUnhosted() {
        let devices = [
            RunDeviceHost(host: nil, name: "iPhone-1", platform: "ios"),
            RunDeviceHost(host: nil, name: "Pixel-1", platform: "android"),
        ]
        XCTAssertEqual(RemoteDispatchDeviceScope.resolve(targetHost: "M1Max", devices: devices), .wholeProfile)
    }

    func testNoDevices() {
        XCTAssertEqual(RemoteDispatchDeviceScope.resolve(targetHost: "M1Max", devices: []), .wholeProfile)
    }

    func testExplicitLocalStringNormalizesToWholeProfile() {
        let devices = [
            RunDeviceHost(host: "local", name: "iPhone-1", platform: "ios"),
            RunDeviceHost(host: " local ", name: "Pixel-1", platform: "android"),
        ]
        XCTAssertEqual(RemoteDispatchDeviceScope.resolve(targetHost: "local", devices: devices), .wholeProfile)
    }

    private func mixedDevices() -> [RunDeviceHost] {
        [
            RunDeviceHost(host: nil, name: "local-ios", platform: "ios"),
            RunDeviceHost(host: nil, name: "local-android", platform: "android"),
            RunDeviceHost(host: "M1Max", name: "m1max-ios", platform: "ios"),
            RunDeviceHost(host: "M1Max", name: "m1max-android", platform: "android"),
            RunDeviceHost(host: "M1Ultra", name: "m1ultra-ios", platform: "ios"),
            RunDeviceHost(host: "M1Ultra", name: "m1ultra-android", platform: "android"),
        ]
    }

    func testFiltersToTheMatchingRemoteHostInProfileOrder() {
        let result = RemoteDispatchDeviceScope.resolve(targetHost: "M1Max", devices: mixedDevices())
        XCTAssertEqual(result, .filtered(deviceNames: ["m1max-ios", "m1max-android"]))
    }

    func testFiltersToTheLocalHost() {
        let result = RemoteDispatchDeviceScope.resolve(targetHost: "local", devices: mixedDevices())
        XCTAssertEqual(result, .filtered(deviceNames: ["local-ios", "local-android"]))
    }

    func testNoneForHostListsAvailableHostsInAppearanceOrder() {
        let result = RemoteDispatchDeviceScope.resolve(targetHost: "M2", devices: mixedDevices())
        XCTAssertEqual(result, .noneForHost(available: ["local", "M1Max", "M1Ultra"]))
    }
}
