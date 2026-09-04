import XCTest
@testable import FTCore

/// `appPathPhysical` 未指定の警告は、appPath 自体が実機用ビルドなら鳴らさない(RunProfile.resolve)。
/// その判定を Info.plist の値だけで固定する
final class AppBundleInspectorPlatformTests: XCTestCase {

    func testIphoneOSMeansDeviceBuild() {
        XCTAssertEqual(AppBundleInspector.isDeviceBuild(supportedPlatforms: ["iPhoneOS"]), true)
        XCTAssertEqual(AppBundleInspector.isDeviceBuild(supportedPlatforms: ["iphoneos"]), true)
    }

    func testSimulatorMeansNotDeviceBuild() {
        XCTAssertEqual(AppBundleInspector.isDeviceBuild(supportedPlatforms: ["iPhoneSimulator"]), false)
    }

    func testUnknownStaysUnknown() {
        XCTAssertNil(AppBundleInspector.isDeviceBuild(supportedPlatforms: nil))
        XCTAssertNil(AppBundleInspector.isDeviceBuild(supportedPlatforms: []))
        XCTAssertNil(AppBundleInspector.declaresDevicePlatform(appPath: nil))
        XCTAssertNil(AppBundleInspector.declaresDevicePlatform(appPath: "/nonexistent/X.app"))
    }

    func testReadsInfoPlistFromBundle() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-inspector-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist: [String: Any] = ["CFBundleSupportedPlatforms": ["iPhoneOS"]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Info.plist"))
        XCTAssertEqual(AppBundleInspector.declaresDevicePlatform(appPath: dir.path), true)
    }
}
