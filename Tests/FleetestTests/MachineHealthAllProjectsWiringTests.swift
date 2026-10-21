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
        XCTAssertTrue(code.contains("machineHealth(runs: machineRuns, records: machineRecords)"),
                      "machineHealth に全プロジェクト分の runs / records を渡していない")
        XCTAssertTrue(code.contains("runs + otherScans.flatMap(\\.runs)"), "machineRuns に他プロジェクトの run を足していない")
    }

    /// 他プロジェクトの run が増えても出力キャッシュが外れること(指紋に他プロジェクトの results/ を混ぜる)
    func testCacheFingerprintCoversOtherProjects() throws {
        let code = try Self.code()
        XCTAssertTrue(code.contains("+ otherProjects.map"), "scanDigest に他プロジェクトの指紋を混ぜていない")
        XCTAssertTrue(code.contains("(machineRuns.map(\\.startedAt) + machineRecords.map(\\.startedAt)).min()"),
                      "窓から落ちた判定(oldestIncluded)が他プロジェクトの記録を見ていない")
    }
}
