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

/// `--host H --device <名前>`(--device-host 無し)は H の台に限定する。同名の台が3機に
/// あるプロファイルで名前だけを渡すと、子が3機ぶんを拾って手元の UDID を向こうで探す
/// (受け手報告 2026-08-23)
final class RemoteDispatchExplicitDeviceScopeTests: XCTestCase {
    private func sameNameOnThreeHosts() -> [RunDeviceHost] {
        [
            RunDeviceHost(host: nil, name: "iPhone 17 Pro(iOS 27.0)-01", platform: "ios"),
            RunDeviceHost(host: "M1Max", name: "iPhone 17 Pro(iOS 27.0)-01", platform: "ios"),
            RunDeviceHost(host: "M1Max", name: "Pixel-01", platform: "android"),
            RunDeviceHost(host: "M1Ultra", name: "iPhone 17 Pro(iOS 27.0)-01", platform: "ios"),
        ]
    }

    func testSameNameOnSeveralHostsIsPinnedToTheTargetHost() {
        XCTAssertEqual(
            RemoteDispatchExplicitDeviceScope.resolve(
                targetHost: "M1Max", requested: ["iPhone 17 Pro(iOS 27.0)-01"], devices: sameNameOnThreeHosts()),
            .pinned)
    }

    func testNameMissingOnTheTargetHostListsThatHostsDevices() {
        XCTAssertEqual(
            RemoteDispatchExplicitDeviceScope.resolve(
                targetHost: "M1Ultra", requested: ["Pixel-01", "iPhone 17 Pro(iOS 27.0)-01"],
                devices: sameNameOnThreeHosts()),
            .notOnHost(missing: ["Pixel-01"], available: ["iPhone 17 Pro(iOS 27.0)-01"]))
    }

    func testUnhostedProfilePassesNamesThrough() {
        let devices = [RunDeviceHost(host: nil, name: "iPhone-1", platform: "ios")]
        XCTAssertEqual(
            RemoteDispatchExplicitDeviceScope.resolve(targetHost: "M1Max", requested: ["iPhone-1"], devices: devices),
            .passThrough)
        XCTAssertEqual(
            RemoteDispatchExplicitDeviceScope.resolve(targetHost: "M1Max", requested: ["iPhone-1"], devices: []),
            .passThrough)
    }

    func testHostWithNoDevicesAtAllReportsEmptyAvailable() {
        XCTAssertEqual(
            RemoteDispatchExplicitDeviceScope.resolve(
                targetHost: "M2", requested: ["iPhone 17 Pro(iOS 27.0)-01"], devices: sameNameOnThreeHosts()),
            .notOnHost(missing: ["iPhone 17 Pro(iOS 27.0)-01"], available: []))
    }
}
