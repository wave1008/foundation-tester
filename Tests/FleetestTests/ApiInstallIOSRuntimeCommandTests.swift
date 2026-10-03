// `fleetest api install-ios-runtime` の判定(decide)だけを固定する。SDK の版と一致しない版は
// 何も入れずに拒み、導入済みなら何もしない(冪等)ことを、デバイス/ネットワーク無しで担保する。

import XCTest
@testable import fleetest

final class ApiInstallIOSRuntimeCommandTests: XCTestCase {

    private let rt27 = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    private let rt26 = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"

    func testInstallsWhenVersionMatchesSDKAndNotInstalled() {
        XCTAssertEqual(
            ApiInstallIOSRuntimeCommand.decide(version: "27.0", sdkVersion: "27.0", installedIdentifiers: [rt26]),
            .install(expectedIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"))
    }

    func testMatchesSDKByMajorMinorOnly() {
        XCTAssertEqual(
            ApiInstallIOSRuntimeCommand.decide(version: "27", sdkVersion: "27.0.1", installedIdentifiers: []),
            .install(expectedIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"))
    }

    func testRefusesVersionDifferentFromSDK() {
        guard case .refuse(let reason) = ApiInstallIOSRuntimeCommand.decide(
            version: "26.2", sdkVersion: "27.0", installedIdentifiers: []) else {
            return XCTFail("expected .refuse")
        }
        XCTAssertTrue(reason.contains("26.2") && reason.contains("27.0"), reason)
    }

    func testRefusesWhenSDKVersionIsUnreadable() {
        guard case .refuse = ApiInstallIOSRuntimeCommand.decide(
            version: "27.0", sdkVersion: nil, installedIdentifiers: []) else {
            return XCTFail("expected .refuse")
        }
    }

    func testDoesNothingWhenAlreadyInstalled() {
        XCTAssertEqual(
            ApiInstallIOSRuntimeCommand.decide(version: "27.0", sdkVersion: "27.0", installedIdentifiers: [rt27]),
            .alreadyInstalled)
        // 導入済みなら SDK の版が読めなくても何もしない(冪等)
        XCTAssertEqual(
            ApiInstallIOSRuntimeCommand.decide(version: "27.0", sdkVersion: nil, installedIdentifiers: [rt27]),
            .alreadyInstalled)
    }

    func testRefusesUnparsableVersion() {
        guard case .refuse = ApiInstallIOSRuntimeCommand.decide(
            version: "beta", sdkVersion: "27.0", installedIdentifiers: []) else {
            return XCTFail("expected .refuse")
        }
    }
}
