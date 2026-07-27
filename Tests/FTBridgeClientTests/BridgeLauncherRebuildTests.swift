import XCTest
@testable import FTBridgeClient

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

    private func makeXCTestRun(modified: Date) throws -> URL {
        let url = root.appendingPathComponent("FTesterRunner_x.xctestrun")
        try Data("r".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
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
        XCTAssertFalse(BridgeLauncher.runnerNeedsRebuild(repoRoot: root, xctestrun: xctestrun))
    }

    func testNewerSourceTriggersRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date(timeIntervalSinceNow: -3600))
        try setModified("Runner/FTesterRunnerUITests/BridgeRouter.swift", Date())
        XCTAssertTrue(BridgeLauncher.runnerNeedsRebuild(repoRoot: root, xctestrun: xctestrun))
    }

    func testNewerSharedDTOTriggersRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date(timeIntervalSinceNow: -3600))
        try setModified("Sources/FTCore/BridgeDTO.swift", Date())
        XCTAssertTrue(BridgeLauncher.runnerNeedsRebuild(repoRoot: root, xctestrun: xctestrun))
    }

    func testUnreadableInputsTriggerRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date())
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("Runner/FTesterRunnerUITests"))
        XCTAssertTrue(BridgeLauncher.runnerNeedsRebuild(repoRoot: root, xctestrun: xctestrun))
    }
}
