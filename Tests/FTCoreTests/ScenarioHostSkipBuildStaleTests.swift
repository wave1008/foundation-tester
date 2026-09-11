// `--skip-build` はソースと食い違う古いシナリオ実行バイナリを警告なしで使っていた
// `ScenarioHost.warnIfSkipBuildStale` が build-fingerprint
// (BuildFingerprint。mtime+size)の食い違いを警告1行に変える。ScenarioHostPackageRootTests と
// 同じ FT_PACKAGE_ROOT オーバーライドでパッケージルートを差し替える

import XCTest
@testable import FTCore

final class ScenarioHostSkipBuildStaleTests: XCTestCase {

    private func withEnv(_ key: String, _ value: String?, _ body: () throws -> Void) rethrows {
        let previous = ProcessInfo.processInfo.environment[key]
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
        try body()
    }

    private func makeRepo() throws -> (repoRoot: URL, project: TestProject, cleanup: () -> Void) {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-skipbuild-\(UUID().uuidString)")
        let sourcesDir = repoRoot.appendingPathComponent("Sources")
        let project = TestProject(name: "Foo", rootURL: repoRoot.appendingPathComponent("TestProjects/Foo"))
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.scenariosDir, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0".write(
            to: repoRoot.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "let x = 1".write(
            to: sourcesDir.appendingPathComponent("Foo.swift"), atomically: true, encoding: .utf8)
        return (repoRoot, project, { try? FileManager.default.removeItem(at: repoRoot) })
    }

    /// 戻すと落ちる根拠: revert すると build-fingerprint を一切見ずに常に何も言わなくなる
    /// (消した一時シナリオが次の run に載っても気づけない)
    func testWarnsWhenNoFingerprintHasEverBeenStored() throws {
        let (repoRoot, project, cleanup) = try makeRepo()
        defer { cleanup() }
        try withEnv("FT_PACKAGE_ROOT", repoRoot.path) {
            var messages: [String] = []
            ScenarioHost.warnIfSkipBuildStale(project: project) { messages.append($0) }
            XCTAssertEqual(messages.count, 1)
            XCTAssertTrue(messages[0].contains("--skip-build"))
        }
    }

    /// フィンガープリントが最後のビルド時と一致していれば黙る(誤検知を出さない)
    func testSilentWhenFingerprintMatchesStoredValue() throws {
        let (repoRoot, project, cleanup) = try makeRepo()
        defer { cleanup() }
        try withEnv("FT_PACKAGE_ROOT", repoRoot.path) {
            let fingerprint = BuildFingerprint.compute(
                repoRoot: repoRoot, scenariosDir: project.scenariosDir)
            let unwrapped = try XCTUnwrap(fingerprint)
            BuildFingerprint.store(unwrapped, productName: project.productName, repoRoot: repoRoot)

            var messages: [String] = []
            ScenarioHost.warnIfSkipBuildStale(project: project) { messages.append($0) }
            XCTAssertTrue(messages.isEmpty)
        }
    }

    /// ビルド後にソースが変わったら再び警告する(古いバイナリのまま走らせる事故の再現形)
    func testWarnsAgainAfterSourceChangesSincePriorBuild() throws {
        let (repoRoot, project, cleanup) = try makeRepo()
        defer { cleanup() }
        try withEnv("FT_PACKAGE_ROOT", repoRoot.path) {
            let fingerprint = BuildFingerprint.compute(
                repoRoot: repoRoot, scenariosDir: project.scenariosDir)
            BuildFingerprint.store(try XCTUnwrap(fingerprint),
                                  productName: project.productName, repoRoot: repoRoot)

            // ソース側の変更(サイズが変わるので mtime の解像度に依存せず検知できる)
            try "let x = 1\nlet y = 2".write(
                to: repoRoot.appendingPathComponent("Sources/Foo.swift"),
                atomically: true, encoding: .utf8)

            var messages: [String] = []
            ScenarioHost.warnIfSkipBuildStale(project: project) { messages.append($0) }
            XCTAssertEqual(messages.count, 1)
        }
    }
}
