import XCTest
@testable import FTCore

/// バンドルマーカー→UI フレームワークの規則だけを対象にする(材料の選び方・順序は AppUIFrameworkQueryTests)
final class AppBundleInspectorTests: XCTestCase {
    func testComposeMarkerWins() {
        XCTAssertEqual(
            AppBundleInspector.uiFramework(composeResourcesExists: true, flutterFrameworkExists: false),
            .compose)
    }

    func testFlutterMarker() {
        XCTAssertEqual(
            AppBundleInspector.uiFramework(composeResourcesExists: false, flutterFrameworkExists: true),
            .flutter)
    }

    func testNoMarkerDefaultsToUIKit() {
        XCTAssertEqual(
            AppBundleInspector.uiFramework(composeResourcesExists: false, flutterFrameworkExists: false),
            .uikit)
    }

    /// 両方実在する(通常は起きないはずの)ケースでも InAppBridge と同じ優先順位(compose 優先)にする
    func testBothMarkersPreferCompose() {
        XCTAssertEqual(
            AppBundleInspector.uiFramework(composeResourcesExists: true, flutterFrameworkExists: true),
            .compose)
    }

    func testDetectByAppPathReadsMarkers() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-inspector-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("compose-resources"),
            withIntermediateDirectories: true)
        XCTAssertEqual(AppBundleInspector.detect(appPath: dir.path), .compose)
    }

    func testDetectByAppPathReturnsNilForMissingPath() {
        XCTAssertNil(AppBundleInspector.detect(appPath: nil))
        XCTAssertNil(AppBundleInspector.detect(appPath: "/nonexistent/FT.app"))
    }
}
