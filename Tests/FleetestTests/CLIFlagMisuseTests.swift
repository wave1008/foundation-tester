// 指定したのに黙って効かない形を作らない(CLAUDE.md「効かせられないなら名指しでエラーにする」):
// ①`doctor --fm-only --roots-only` は run() が --roots-only を先に見て抜け、--fm-only が黙って効かなかった
// ②`api host-metrics-summary --log <無いファイル>` は空の集計を exit 0 で返していた(run から解決した場所に
//   無いのは「記録していない」= 標本 0 の事実なので、そちらは従来どおり)
// ③`run --dry-run --junit` は JUnit を黙って書かなかった
// ④`api dsl-commands --category` の help の分類一覧が手書きで `id` を欠いていた(索引から導出する)

import XCTest
import ArgumentParser
import FTCore
@testable import fleetest

final class CLIFlagMisuseTests: XCTestCase {

    func testDoctorRejectsFmOnlyWithRootsOnly() {
        XCTAssertThrowsError(try Doctor.parse(["--fm-only", "--roots-only"])) { error in
            XCTAssertTrue(Doctor.message(for: error).contains("--fm-only cannot be combined with --roots-only"),
                          Doctor.message(for: error))
        }
    }

    func testDoctorStillAcceptsEachAlone() throws {
        XCTAssertNoThrow(try Doctor.parse(["--fm-only"]))
        XCTAssertNoThrow(try Doctor.parse(["--roots-only"]))
    }

    func testHostMetricsSummaryRejectsAMissingExplicitLog() throws {
        var command = try ApiHostMetricsSummaryCommand.parse(["--log", "/nonexistent-\(UUID().uuidString).ndjson"])
        XCTAssertThrowsError(try command.run()) { error in
            XCTAssertTrue("\(error)".contains("--log file not found"), "\(error)")
        }
    }

    func testRunRejectsJUnitWithDryRun() {
        let path = NSTemporaryDirectory() + "junit-\(UUID().uuidString).xml"
        XCTAssertThrowsError(try RunScenarios.parse(["--dry-run", "--junit", path])) { error in
            XCTAssertTrue(RunScenarios.message(for: error).contains("--junit cannot be combined with --dry-run"),
                          RunScenarios.message(for: error))
        }
        XCTAssertNoThrow(try RunScenarios.parse(["--junit", path]))
    }

    func testCategoryHelpListsEveryCategoryInTheIndex() {
        let listed = Set(DSLCommandIndex.categories)
        XCTAssertEqual(listed, Set(DSLCommandIndex.all.map(\.category)))
        XCTAssertTrue(listed.contains("id"))
    }
}
