import XCTest
@testable import FTCore

/// platform と宛先(iOS: udid/port・Android: serial)の食い違い判定(真理値表)。
/// MCP(fleetest-mcp)と CLI(fleetest)の両方がこの1箇所を通す。
final class DeviceTargetConsistencyTests: XCTestCase {

    // MARK: - 食い違い(拒否すべき)

    func testBothTargetsWithNoPlatformIsAmbiguous() {
        XCTAssertEqual(
            DeviceTargetConsistency.mismatch(platform: nil, gaveIOSTarget: true, gaveAndroidTarget: true),
            .bothPlatformsTargeted)
    }

    func testIOSPlatformWithAndroidTargetIsAMismatch() {
        XCTAssertEqual(
            DeviceTargetConsistency.mismatch(platform: "ios", gaveIOSTarget: false, gaveAndroidTarget: true),
            .iosPlatformWithAndroidTarget)
        // iOS の宛先も一緒に与えられていても、Android の宛先がある時点で食い違い
        XCTAssertEqual(
            DeviceTargetConsistency.mismatch(platform: "ios", gaveIOSTarget: true, gaveAndroidTarget: true),
            .iosPlatformWithAndroidTarget)
    }

    func testAndroidPlatformWithIOSTargetIsAMismatch() {
        XCTAssertEqual(
            DeviceTargetConsistency.mismatch(platform: "android", gaveIOSTarget: true, gaveAndroidTarget: false),
            .androidPlatformWithIOSTarget)
        XCTAssertEqual(
            DeviceTargetConsistency.mismatch(platform: "android", gaveIOSTarget: true, gaveAndroidTarget: true),
            .androidPlatformWithIOSTarget)
    }

    // MARK: - 食い違わない(拒否してはいけない)

    func testNoPlatformWithOnlyAndroidTargetIsFine() {
        XCTAssertNil(DeviceTargetConsistency.mismatch(platform: nil, gaveIOSTarget: false, gaveAndroidTarget: true))
    }

    func testAndroidPlatformWithSerialIsFine() {
        XCTAssertNil(DeviceTargetConsistency.mismatch(platform: "android", gaveIOSTarget: false, gaveAndroidTarget: true))
    }

    func testIOSPlatformWithUDIDAndPortIsFine() {
        XCTAssertNil(DeviceTargetConsistency.mismatch(platform: "ios", gaveIOSTarget: true, gaveAndroidTarget: false))
    }

    func testEverythingOmittedIsFine() {
        XCTAssertNil(DeviceTargetConsistency.mismatch(platform: nil, gaveIOSTarget: false, gaveAndroidTarget: false))
    }

    func testNoPlatformWithOnlyIOSTargetIsFine() {
        XCTAssertNil(DeviceTargetConsistency.mismatch(platform: nil, gaveIOSTarget: true, gaveAndroidTarget: false))
    }

    // MARK: - defaultPlatform

    func testDefaultPlatformInfersAndroidFromSerialAlone() {
        XCTAssertEqual(DeviceTargetConsistency.defaultPlatform(explicit: nil, gaveIOSTarget: false, gaveAndroidTarget: true), "android")
    }

    func testDefaultPlatformIsIOSOtherwise() {
        XCTAssertEqual(DeviceTargetConsistency.defaultPlatform(explicit: nil, gaveIOSTarget: false, gaveAndroidTarget: false), "ios")
        XCTAssertEqual(DeviceTargetConsistency.defaultPlatform(explicit: nil, gaveIOSTarget: true, gaveAndroidTarget: false), "ios")
        XCTAssertEqual(DeviceTargetConsistency.defaultPlatform(explicit: nil, gaveIOSTarget: true, gaveAndroidTarget: true), "ios")
    }

    func testDefaultPlatformKeepsTheExplicitValue() {
        XCTAssertEqual(DeviceTargetConsistency.defaultPlatform(explicit: "ios", gaveIOSTarget: false, gaveAndroidTarget: true), "ios")
        XCTAssertEqual(DeviceTargetConsistency.defaultPlatform(explicit: "android", gaveIOSTarget: false, gaveAndroidTarget: false), "android")
    }
}
