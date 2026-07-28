import XCTest
@testable import FTBridgeClient
import FTCore

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

    /// 指紋を一致させたうえで mtime 判定だけを見る(指紋の検証は下の2本)
    private func needsBuild(toolchain: String = "Xcode X / sdk Y") -> Bool {
        InAppLauncher.needsBuild(repoRoot: root, toolchain: toolchain)
    }

    private func storeFingerprint(_ value: String) {
        ToolchainFingerprint.store(
            at: InAppLauncher.fingerprintPath(repoRoot: root), current: value)
    }

    func testNeedsBuildWhenDylibMissing() {
        XCTAssertTrue(needsBuild())
    }

    /// Xcode/SDK を上げてもソースの mtime は動かない。指紋の不一致で作り直す
    /// (旧 SDK の dylib を新ランタイムへ注入すると実行時に落ちる)
    func testNeedsBuildWhenToolchainChanged() throws {
        try buildDylib(at: Date().addingTimeInterval(60))
        storeFingerprint("Xcode 27.0 Build 27A1 / iphonesimulator 27A1")
        XCTAssertTrue(InAppLauncher.needsBuild(
            repoRoot: root, toolchain: "Xcode 27.1 Build 27B2 / iphonesimulator 27B2"))
    }

    /// 指紋が無い(旧版で作った dylib)ときも作り直す = 判定不能は再ビルド側へ倒す
    func testNeedsBuildWhenFingerprintMissing() throws {
        try buildDylib(at: Date().addingTimeInterval(60))
        XCTAssertTrue(needsBuild())
    }

    func testNoBuildWhenDylibIsNewerThanAllInputs() throws {
        try buildDylib(at: Date().addingTimeInterval(60))
        storeFingerprint("Xcode X / sdk Y")
        XCTAssertFalse(needsBuild())
    }

    /// 本命: ブリッジのソースだけを触ったケース
    func testNeedsBuildWhenBridgeSourceIsNewer() throws {
        try buildDylib(at: Date())
        try write("InAppBridge/Sources/InAppSnapshot.swift", at: Date().addingTimeInterval(60))
        storeFingerprint("Xcode X / sdk Y")
        XCTAssertTrue(needsBuild())
    }

    /// 共有 DTO も dylib の入力(build.sh の SWIFT_SOURCES に入っている)
    func testNeedsBuildWhenSharedDTOIsNewer() throws {
        try buildDylib(at: Date())
        try write("Sources/FTCore/BridgeDTO.swift", at: Date().addingTimeInterval(60))
        storeFingerprint("Xcode X / sdk Y")
        XCTAssertTrue(needsBuild())
    }

    func testNeedsBuildWhenBuildScriptIsNewer() throws {
        try buildDylib(at: Date())
        try write("InAppBridge/build.sh", at: Date().addingTimeInterval(60))
        storeFingerprint("Xcode X / sdk Y")
        XCTAssertTrue(needsBuild())
    }

    /// 入力が読めない(構成が違う)ときは「判定不能」= 再ビルド側へ倒す
    func testNeedsBuildWhenInputsAreUnreadable() throws {
        try buildDylib(at: Date().addingTimeInterval(60))
        storeFingerprint("Xcode X / sdk Y")
        try FileManager.default.removeItem(at: root.appendingPathComponent("InAppBridge/Sources"))
        XCTAssertTrue(needsBuild())
    }
}
