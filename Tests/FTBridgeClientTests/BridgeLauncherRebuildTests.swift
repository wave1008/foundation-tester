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
        for dir in ["Runner/FleetestRunnerUITests", "Runner/FleetestRunnerApp", "Sources/FTCore"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["Runner/project.yml", "Runner/FleetestRunnerUITests/BridgeRouter.swift",
                     "Runner/FleetestRunnerApp/App.swift", "Sources/FTCore/BridgeDTO.swift"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(file))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let toolchain = "Xcode X / sdk Y"

    private func makeXCTestRun(modified: Date) throws -> URL {
        let url = root.appendingPathComponent("FleetestRunner_x.xctestrun")
        try Data("r".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        // 成果物と同じ場所にツールチェーンの指紋を置く(実運用では DerivedData ルート)
        ToolchainFingerprint.store(
            at: BridgeLauncher.runnerFingerprintPath(derivedDataPath: root), current: toolchain)
        return url
    }

    private func needsRebuild(_ xctestrun: URL, signing: String = "",
                              toolchain: String? = nil) -> Bool {
        BridgeLauncher.runnerNeedsRebuild(
            repoRoot: root, xctestrun: xctestrun, signing: signing,
            toolchain: toolchain ?? self.toolchain)
    }

    private func setModified(_ relPath: String, _ date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: root.appendingPathComponent(relPath).path)
    }

    func testFreshXCTestRunDoesNotRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date())
        for file in ["Runner/project.yml", "Runner/FleetestRunnerUITests/BridgeRouter.swift",
                     "Runner/FleetestRunnerApp/App.swift", "Sources/FTCore/BridgeDTO.swift"] {
            try setModified(file, Date(timeIntervalSinceNow: -3600))
        }
        XCTAssertFalse(needsRebuild(xctestrun))
    }

    func testNewerSourceTriggersRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date(timeIntervalSinceNow: -3600))
        try setModified("Runner/FleetestRunnerUITests/BridgeRouter.swift", Date())
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
            at: root.appendingPathComponent("Runner/FleetestRunnerUITests"))
        XCTAssertTrue(needsRebuild(xctestrun))
    }

    /// Xcode/SDK を上げてもソースの mtime は動かない。指紋の不一致で作り直す
    /// (旧 Xcode のランナーを新ランタイムに載せると実行中に落ちる)
    func testToolchainChangeTriggersRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date())
        for file in ["Runner/project.yml", "Runner/FleetestRunnerUITests/BridgeRouter.swift",
                     "Runner/FleetestRunnerApp/App.swift", "Sources/FTCore/BridgeDTO.swift"] {
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

/// BridgeLauncher.staleRunnerToolchain(doctor が出す「ランナーが別のツールチェーン」警告の判定)。
/// 再ビルドの砦と違い、**未ビルドでは黙る**(作り直しの必要ではなく未導入)。
final class StaleRunnerToolchainTests: XCTestCase {
    private var root: URL!
    private let toolchain = "Xcode 27.0 Build version 27A5252f / iphonesimulator 24A5422a"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-stale-toolchain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func storeFingerprint(_ value: String, physical: Bool = false) {
        let derivedData = root.appendingPathComponent(
            ".fleetest/\(physical ? "DerivedData-device" : "DerivedData")")
        ToolchainFingerprint.store(
            at: BridgeLauncher.runnerFingerprintPath(derivedDataPath: derivedData), current: value)
    }

    private func stale(physical: Bool = false, current: String? = nil) -> String? {
        BridgeLauncher.staleRunnerToolchain(
            repoRoot: root, physical: physical, current: current ?? toolchain)
    }

    func testMatchingToolchainIsSilent() {
        storeFingerprint(toolchain)
        XCTAssertNil(stale())
    }

    /// Xcode beta を上げた形。保存されていた指紋をそのまま名指しする(何と食い違うか分かるように)
    func testDifferentToolchainReportsStoredFingerprint() {
        let old = "Xcode 27.0 Build version 27A5237l / iphonesimulator 24A5408c"
        storeFingerprint(old)
        XCTAssertEqual(stale(), old)
    }

    /// SDK だけ動いた形も不一致(ランタイムが入れ替わるとランナーは載らない)
    func testSDKOnlyChangeIsStale() {
        storeFingerprint("Xcode 27.0 Build version 27A5252f / iphonesimulator 24A5408c")
        XCTAssertNotNil(stale())
    }

    func testMissingFingerprintIsSilent() {
        XCTAssertNil(stale())
    }

    /// 現在のツールチェーンが採れないときは黙る(比較相手が無いのに警告しない)
    func testUnknownCurrentToolchainIsSilent() {
        storeFingerprint("Xcode 26.0 Build version 26A1 / iphonesimulator 23A1")
        XCTAssertNil(BridgeLauncher.staleRunnerToolchain(repoRoot: root, current: nil))
    }

    /// 実機用の成果物は別の DerivedData に居る(シミュレータの指紋と混ざらない)
    func testPhysicalUsesItsOwnDerivedData() {
        storeFingerprint(toolchain, physical: false)
        storeFingerprint("Xcode 26.0 Build version 26A1 / iphonesimulator 23A1", physical: true)
        XCTAssertNil(stale(physical: false))
        XCTAssertNotNil(stale(physical: true))
    }
}

// MARK: - 署名設定の指紋(.signing)

/// 署名設定(チーム・接頭辞)の変更はソースの mtime もツールチェーンも動かさないため、
/// 独立した指紋で見る(2026-08-31 実害: チーム切替後も旧 bundle id のランナーを起動し続け、
/// ビルド成功なのに「not installed (-10814)」で落ちた)
extension BridgeLauncherRebuildTests {
    private func storeSigning(_ value: String) throws {
        try (value + "\n").write(to: root.appendingPathComponent(".signing"),
                                  atomically: true, encoding: .utf8)
    }

    func testChangedSigningTriggersRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date())
        try storeSigning("DEVELOPMENT_TEAM=AAA")
        XCTAssertTrue(needsRebuild(xctestrun, signing: "DEVELOPMENT_TEAM=BBB"))
    }

    func testMatchingSigningDoesNotRebuild() throws {
        let xctestrun = try makeXCTestRun(modified: Date())
        try storeSigning("DEVELOPMENT_TEAM=AAA")
        XCTAssertFalse(needsRebuild(xctestrun, signing: "DEVELOPMENT_TEAM=AAA"))
    }

    func testMissingSigningFingerprintRebuildsForPhysical() throws {
        let xctestrun = try makeXCTestRun(modified: Date())
        XCTAssertTrue(needsRebuild(xctestrun, signing: "DEVELOPMENT_TEAM=AAA"),
                      "この仕組み以前の成果物は一度だけ建て直す(古いまま走らせない)")
    }

    func testEmptySigningNeverRebuilds() throws {
        // シミュレータ(署名なし)は指紋の有無に関わらず建て直さない
        let xctestrun = try makeXCTestRun(modified: Date())
        XCTAssertFalse(needsRebuild(xctestrun, signing: ""))
        try storeSigning("DEVELOPMENT_TEAM=AAA")
        XCTAssertFalse(needsRebuild(xctestrun, signing: ""))
    }
}

