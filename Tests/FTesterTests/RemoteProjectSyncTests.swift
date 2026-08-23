import Foundation
import XCTest
@testable import ftester

final class RemoteProjectSyncTests: XCTestCase {

    func testPrefersTheResolvedProjectOverTheToolClone() {
        XCTAssertEqual(
            RemoteProjectSync.localProjectsDir(
                resolvedProjectRoot: URL(fileURLWithPath: "/Users/r/dev/E2E-app/TestProjects/E2E-app"),
                repoRoot: URL(fileURLWithPath: "/Users/r/dev/foundation-tester")),
            "/Users/r/dev/E2E-app/TestProjects",
            "外部パッケージ構成: プロジェクトは受け手パッケージ側にあり、クローンの TestProjects/ には無い")
    }

    func testFallsBackToTheToolCloneWhenNoPackageResolves() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rps-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(
            RemoteProjectSync.localProjectsDir(resolvedProjectRoot: nil, repoRoot: tmp),
            tmp.appendingPathComponent("TestProjects").path)
        XCTAssertNil(RemoteProjectSync.localProjectsDir(resolvedProjectRoot: nil, repoRoot: nil))
    }
}
