import XCTest
@testable import FTCore

/// バンドルマーカー→uiFramework の純粋関数部だけを対象にする(プロセス起動部は単体テスト対象外。
/// AppBundleInspector.swift のコメント参照)。マーカー規則は InAppBridge.uiFramework と同一で、
/// ここが割れると engine=xcuitest だけ判定が食い違う
final class AppBundleInspectorTests: XCTestCase {
    func testComposeMarkerWins() {
        XCTAssertEqual(
            AppBundleInspector.uiFramework(composeResourcesExists: true, flutterFrameworkExists: false),
            "compose")
    }

    func testFlutterMarker() {
        XCTAssertEqual(
            AppBundleInspector.uiFramework(composeResourcesExists: false, flutterFrameworkExists: true),
            "flutter")
    }

    func testNoMarkerDefaultsToUIKit() {
        XCTAssertEqual(
            AppBundleInspector.uiFramework(composeResourcesExists: false, flutterFrameworkExists: false),
            "uikit")
    }

    /// 両方実在する(通常は起きないはずの)ケースでも InAppBridge と同じ優先順位(compose 優先)にする
    func testBothMarkersPreferCompose() {
        XCTAssertEqual(
            AppBundleInspector.uiFramework(composeResourcesExists: true, flutterFrameworkExists: true),
            "compose")
    }

    func testDetectReturnsNilForPhysicalDevice() {
        XCTAssertNil(AppBundleInspector.detect(udid: "00000000-AAAA", bundleID: "com.example.app",
                                               physical: true))
    }

    func testDetectReturnsNilWithoutUDID() {
        XCTAssertNil(AppBundleInspector.detect(udid: nil, bundleID: "com.example.app", physical: false))
    }

    func testDetectByAppPathReadsMarkers() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-inspector-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("compose-resources"),
            withIntermediateDirectories: true)
        XCTAssertEqual(AppBundleInspector.detect(appPath: dir.path), "compose")
    }

    func testDetectByAppPathReturnsNilForMissingPath() {
        XCTAssertNil(AppBundleInspector.detect(appPath: nil))
        XCTAssertNil(AppBundleInspector.detect(appPath: "/nonexistent/FT.app"))
    }

    // MARK: - 自己申告が取れなかったときの受け皿

    /// **実機でも答えが出ること**が要点: バンドルは手元にあるので、デバイスの応答を
    /// 待たずに判定できる(プローブの締切に判断を預けない)。
    /// RN は compose でも flutter でもないので "uikit" = 空打ちを打たない側に落ちる
    func testCombinedDetectAnswersFromTheBundleEvenForAPhysicalDevice() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-inspector-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(AppBundleInspector.detect(appPath: dir.path, udid: nil,
                                                 bundleID: "com.example.rn", physical: true),
                       "uikit")
    }

    /// バンドルが手元に無ければ**嘘をつかず nil**(呼び手が「不明のまま進む」と名乗る)
    func testCombinedDetectStaysUnknownWithoutABundle() {
        XCTAssertNil(AppBundleInspector.detect(appPath: nil, udid: nil,
                                               bundleID: "com.example.rn", physical: true))
        XCTAssertNil(AppBundleInspector.detect(appPath: "/nonexistent/FT.app", udid: nil,
                                               bundleID: "com.example.rn", physical: true))
    }
}
