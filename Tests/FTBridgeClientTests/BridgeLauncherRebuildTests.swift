import XCTest
@testable import FTBridgeClient
import FTCore

/// BridgeLauncher.runnerNeedsRebuild(xctestrun の鮮度判定)。
/// InAppLauncher.needsBuild と対の規約: ソースが新しい/判定不能 → 再ビルド
final class BridgeLauncherRebuildTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-launcher-rebuild-\(UUID().uuidString)")
        for dir in ["Runner/FTesterRunnerUITests", "Runner/FTesterRunnerApp", "Sources/FTCore"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["Runner/project.yml", "Runner/FTesterRunnerUITests/BridgeRouter.swift",
                     "Runner/FTesterRunnerApp/App.swift", "Sources/FTCore/BridgeDTO.swift"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(file))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let toolchain = "Xcode X / sdk Y"

    private func makeXCTestRun(modified: Date) throws -> URL {
        let url = root.appendingPathComponent("FTesterRunner_x.xctestrun")
        try Data("r".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        // 成果物と同じ場所にツールチェーンの指紋を置く(実運用では DerivedData ルート)
        ToolchainFingerprint.store(
            at: BridgeLauncher.runnerFingerprintPath(derivedDataPath: root), current: toolchain)
        return url
    }

    private func needsRebuild(_ xctestrun: URL, toolchain: String? = nil) -> Bool {
        BridgeLauncher.runnerNeedsRebuild(
            repoRoot: root, xctestrun: xctestrun, toolchain: toolchain ?? self.toolchain)
    }

    private func setModified(_ relPath: String, _ date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: root.appendingPathComponent(relPath).path)
    }

    func testFreshXCTestRunDoesNotRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date())
        for file in ["Runner/project.yml", "Runner/FTesterRunnerUITests/BridgeRouter.swift",
                     "Runner/FTesterRunnerApp/App.swift", "Sources/FTCore/BridgeDTO.swift"] {
            try setModified(file, Date(timeIntervalSinceNow: -3600))
        }
        XCTAssertFalse(needsRebuild(xctestrun))
    }

    func testNewerSourceTriggersRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date(timeIntervalSinceNow: -3600))
        try setModified("Runner/FTesterRunnerUITests/BridgeRouter.swift", Date())
        XCTAssertTrue(needsRebuild(xctestrun))
    }

    func testNewerSharedDTOTriggersRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date(timeIntervalSinceNow: -3600))
        try setModified("Sources/FTCore/BridgeDTO.swift", Date())
        XCTAssertTrue(needsRebuild(xctestrun))
    }

    func testUnreadableInputsTriggerRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date())
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("Runner/FTesterRunnerUITests"))
        XCTAssertTrue(needsRebuild(xctestrun))
    }

    /// Xcode/SDK を上げてもソースの mtime は動かない。指紋の不一致で作り直す
    /// (旧 Xcode のランナーを新ランタイムに載せると実行中に落ちる)
    func testToolchainChangeTriggersRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date())
        for file in ["Runner/project.yml", "Runner/FTesterRunnerUITests/BridgeRouter.swift",
                     "Runner/FTesterRunnerApp/App.swift", "Sources/FTCore/BridgeDTO.swift"] {
            try setModified(file, Date(timeIntervalSinceNow: -3600))
        }
        XCTAssertTrue(needsRebuild(xctestrun, toolchain: "Xcode 27.1 / sdk 27B2"))
    }

    /// 指紋が無い(旧版で作った成果物)ときも作り直す = 判定不能は再ビルド側へ倒す
    func testMissingFingerprintTriggersRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date())
        try FileManager.default.removeItem(
            at: BridgeLauncher.runnerFingerprintPath(derivedDataPath: root))
        XCTAssertTrue(needsRebuild(xctestrun))
    }
}
