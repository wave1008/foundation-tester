import XCTest
@testable import FTCore

/// iOS の目印の規則(UIFrameworkMarkers = in-app ブリッジと共有)と、.app からの読み口。
/// 材料の選び方・順序は AppUIFrameworkQueryTests
final class AppBundleInspectorTests: XCTestCase {
    /// バンドルの見立て。files = 実在する相対パス / binaries = 実行ファイル名 → 中身
    private func judge(files: Set<String> = [], executable: String? = "App",
                       binaries: [String: String] = [:], contentsRead: ((String) -> Void)? = nil) -> AppUIFramework {
        let roots = Set((files.map { String($0.split(separator: "/").first!) }) + binaries.keys)
        return UIFrameworkMarkers.iosFramework(
            executable: executable, rootEntries: Array(roots),
            exists: { path in files.contains { $0 == path || $0.hasPrefix(path + "/") } },
            contents: { name in contentsRead?(name); return binaries[name].map { Data($0.utf8) } })
    }

    func testComposeByResourcesOrTheSkikoClassInEitherBinary() {
        XCTAssertEqual(judge(files: ["compose-resources"]), .compose)
        XCTAssertEqual(judge(binaries: ["App": "…SkikoUIView…"]), .compose)
        XCTAssertEqual(judge(binaries: ["App": "stub", "App.debug.dylib": "…SkikoUIView…"]), .compose)
    }

    /// CMP の iOS 側の入口は SwiftUI の App(E2E-CMP の実バンドルがこの形)。compose が先
    func testComposeWinsOverTheSwiftUIEntryItShipsWith() {
        XCTAssertEqual(judge(binaries: ["App.debug.dylib": "SkikoUIView $s7SwiftUI3AppPAAE4mainyyFZ"]), .compose)
    }

    func testFlutterByTheEngineFramework() {
        XCTAssertEqual(judge(files: ["Frameworks/Flutter.framework/Flutter"]), .flutter)
    }

    /// フレームワーク構成(E2E-RN の実バンドル)でも、静的リンク構成(実行ファイルにクラス名だけ)でも
    func testReactNativeByFrameworksOrTheBridgeClass() {
        XCTAssertEqual(judge(files: ["Frameworks/React.framework/React"]), .reactNative)
        XCTAssertEqual(judge(files: ["Frameworks/hermesvm.framework/hermesvm"]), .reactNative)
        XCTAssertEqual(judge(files: ["Frameworks/hermes.framework/hermes"]), .reactNative)
        XCTAssertEqual(judge(binaries: ["App": "…RCTBridge…"]), .reactNative)
    }

    func testSwiftUIByTheAppEntryAndUIKitOtherwise() {
        XCTAssertEqual(judge(binaries: ["App.debug.dylib": "_$s7SwiftUI3AppPAAE4mainyyFZ"]), .swiftUI)
        XCTAssertEqual(judge(binaries: ["App": "UIHostingController"]), .uikit,
                       "SwiftUI の画面を載せただけの UIKit アプリは uikit(起動の形で決める)")
        XCTAssertEqual(judge(binaries: ["App": "plain"]), .uikit)
        XCTAssertEqual(judge(executable: nil), .uikit)
    }

    /// 目印がファイルだけで決まる回は実行ファイル(数十 MB)を読まない
    func testBinariesAreReadOnlyWhenNeeded() {
        var read: [String] = []
        XCTAssertEqual(judge(files: ["compose-resources"], binaries: ["App": "x"], contentsRead: { read.append($0) }),
                       .compose)
        XCTAssertEqual(read, [])
        _ = judge(binaries: ["App": "x", "App.debug.dylib": "y"], contentsRead: { read.append($0) })
        XCTAssertEqual(read, ["App", "App.debug.dylib"], "実行ファイルは各 1 回だけ読む")
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
