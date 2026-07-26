import XCTest
@testable import FTBridgeClient

/// in-app dylib の再ビルド判定。存在チェックだけだった頃、ブリッジのソースを直しても古い dylib が
/// 注入され続け、ios-inapp/ios-heal だけ「checked が取れない」「switch 型が出ない」で落ちた
/// (2026-07-27)。入力(InAppBridge/Sources/* + build.sh + 共有 DTO)の更新を必ず検知すること。
final class InAppLauncherBuildTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-inapp-build-\(UUID().uuidString)")
        for dir in ["InAppBridge/Sources", "InAppBridge/build", "Sources/FTCore"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try write("InAppBridge/build.sh")
        try write("InAppBridge/Sources/InAppSnapshot.swift")
        try write("Sources/FTCore/BridgeDTO.swift")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, at date: Date = Date()) throws {
        let url = root.appendingPathComponent(path)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func buildDylib(at date: Date) throws {
        try write("InAppBridge/build/libFTInAppBridge.dylib", at: date)
    }

    func testNeedsBuildWhenDylibMissing() {
        XCTAssertTrue(InAppLauncher.needsBuild(repoRoot: root))
    }

    func testNoBuildWhenDylibIsNewerThanAllInputs() throws {
        try buildDylib(at: Date().addingTimeInterval(60))
        XCTAssertFalse(InAppLauncher.needsBuild(repoRoot: root))
    }

    /// 本命: ブリッジのソースだけを触ったケース
    func testNeedsBuildWhenBridgeSourceIsNewer() throws {
        try buildDylib(at: Date())
        try write("InAppBridge/Sources/InAppSnapshot.swift", at: Date().addingTimeInterval(60))
        XCTAssertTrue(InAppLauncher.needsBuild(repoRoot: root))
    }

    /// 共有 DTO も dylib の入力(build.sh の SWIFT_SOURCES に入っている)
    func testNeedsBuildWhenSharedDTOIsNewer() throws {
        try buildDylib(at: Date())
        try write("Sources/FTCore/BridgeDTO.swift", at: Date().addingTimeInterval(60))
        XCTAssertTrue(InAppLauncher.needsBuild(repoRoot: root))
    }

    func testNeedsBuildWhenBuildScriptIsNewer() throws {
        try buildDylib(at: Date())
        try write("InAppBridge/build.sh", at: Date().addingTimeInterval(60))
        XCTAssertTrue(InAppLauncher.needsBuild(repoRoot: root))
    }

    /// 入力が読めない(構成が違う)ときは「判定不能」= 再ビルド側へ倒す
    func testNeedsBuildWhenInputsAreUnreadable() throws {
        try buildDylib(at: Date().addingTimeInterval(60))
        try FileManager.default.removeItem(at: root.appendingPathComponent("InAppBridge/Sources"))
        XCTAssertTrue(InAppLauncher.needsBuild(repoRoot: root))
    }
}
