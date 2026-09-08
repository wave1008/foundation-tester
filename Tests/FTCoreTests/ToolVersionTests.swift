import Foundation
import XCTest
@testable import FTCore

final class ToolVersionTests: XCTestCase {
    /// このテストファイル自身の場所から3階層上(Tests/FTCoreTests/<file> → Tests/FTCoreTests →
    /// Tests → リポジトリルート)を起点にすれば `.git` が必ず見つかる
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testDescribeReturnsNonEmptyString() {
        XCTAssertFalse(ToolVersion.describe().isEmpty)
    }

    func testDescribeContainsProtocolVersion() {
        XCTAssertTrue(ToolVersion.describe().contains("(protocol "))
    }

    func testDescribeStartingAtRepoRootFindsRevision() {
        let described = ToolVersion.describe(startingAt: Self.repoRoot)
        XCTAssertTrue(described.contains("(protocol \(fleetestProtocolVersion))"))
        // このリポジトリは .git を持つ正常なチェックアウトなので "unknown" にはならない
        XCTAssertFalse(described.hasPrefix("unknown"))
    }

    func testDescribeStartingAtDirectoryWithNoGitReturnsUnknown() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-toolversion-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let described = ToolVersion.describe(startingAt: empty)
        XCTAssertTrue(described.hasPrefix("unknown (protocol "))
    }
}
