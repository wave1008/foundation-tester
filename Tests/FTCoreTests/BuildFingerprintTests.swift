import XCTest
@testable import FTCore

final class BuildFingerprintTests: XCTestCase {
    var repoRoot: URL!
    var scenariosDir: URL!

    override func setUpWithError() throws {
        repoRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-repo-\(UUID().uuidString)")
        scenariosDir = repoRoot.appendingPathComponent("Scenarios")
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: scenariosDir, withIntermediateDirectories: true)
        try "// Package.swift".write(
            to: repoRoot.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "{}".write(
            to: repoRoot.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        try "// xx".write(
            to: repoRoot.appendingPathComponent("Sources/xx.swift"), atomically: true, encoding: .utf8)
        try "// yy".write(
            to: scenariosDir.appendingPathComponent("yy.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoRoot)
    }

    func testSameStateProducesSameFingerprint() {
        let a = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        let b = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func testAddingFileChangesFingerprint() throws {
        let before = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        try "// zz".write(
            to: repoRoot.appendingPathComponent("Sources/zz.swift"), atomically: true, encoding: .utf8)
        let after = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        XCTAssertNotEqual(before, after)
    }

    func testMtimeOnlyChangeChangesFingerprint() throws {
        let before = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        let path = repoRoot.appendingPathComponent("Sources/xx.swift").path
        let newDate = Date().addingTimeInterval(3600)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: path)
        let after = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        XCTAssertNotEqual(before, after, "内容・サイズが同じでも mtime 変更で変わるはず")
    }

    func testToolchainIdentityChangesFingerprint() {
        let a = BuildFingerprint.compute(
            repoRoot: repoRoot, scenariosDir: scenariosDir, toolchainIdentity: "toolchain-a")
        let b = BuildFingerprint.compute(
            repoRoot: repoRoot, scenariosDir: scenariosDir, toolchainIdentity: "toolchain-b")
        XCTAssertNotEqual(a, b)
    }

    func testStoreAndStoredRoundTrip() {
        BuildFingerprint.store("abc123", productName: "ftester-scenarios-Sample", repoRoot: repoRoot)
        let stored = BuildFingerprint.stored(
            productName: "ftester-scenarios-Sample", repoRoot: repoRoot)
        XCTAssertEqual(stored, "abc123")
    }

    func testMissingSourcesDirReturnsNil() throws {
        try FileManager.default.removeItem(at: repoRoot.appendingPathComponent("Sources"))
        let fingerprint = BuildFingerprint.compute(repoRoot: repoRoot, scenariosDir: scenariosDir)
        XCTAssertNil(fingerprint)
    }
}
