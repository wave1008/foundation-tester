import Foundation
import XCTest

/// ダッシュボードの「マシンの健全性」は集計期間だけで絞り、プロジェクトでは絞らない(`api results` の
/// `machineHealth` は TestProjects/ の全プロジェクトの結果から数える)。選択中プロジェクトの `runs` /
/// `records` を渡しても型は通るので、配線をソース走査で固定する
final class MachineHealthAllProjectsWiringTests: XCTestCase {

    private static func code() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Sources/fleetest/ApiResultsCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//")[0] }
            .joined(separator: "\n")
    }

    func testMachineHealthReadsEveryProject() throws {
        let code = try Self.code()
        XCTAssertTrue(code.contains("ProjectStore.all(repoRoot:"), "他のプロジェクトを列挙していない")
        XCTAssertTrue(code.contains("[RunResultsQuery.machineHealth(runs: runs, records: records)] + otherParts.map(\\.rows)"),
                      "machineHealth にこのプロジェクト → 他プロジェクトの順で部分結果を合わせていない")
        XCTAssertTrue(code.contains("machineHealth: machineHealth,"), "合わせた machineHealth を出力に載せていない")
        XCTAssertTrue(code.contains("readCache: !noCache"), "--no-cache が部分結果のキャッシュも読まないこと")
    }

    /// 他プロジェクトの run が増えても出力キャッシュが外れること(指紋に他プロジェクトの results/ を混ぜる)
    func testCacheFingerprintCoversOtherProjects() throws {
        let code = try Self.code()
        XCTAssertTrue(code.contains("zip(otherProjects, otherDigests).map { other, digest in other.name"),
                      "scanDigest に他プロジェクトの指紋を混ぜていない")
        XCTAssertTrue(code.contains("+ otherParts.compactMap(\\.oldestIncludedStartedAt)).min()"),
                      "窓から落ちた判定(oldestIncluded)が他プロジェクトの記録を見ていない")
    }
}
