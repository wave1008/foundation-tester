// xcodebuild の失敗出力の要約(XcodebuildFailureSummary)。本当の原因行(error:)が対象外の
// 宛先一覧(`{ platform:… }`)の前に出るのに、単純な末尾30行だと一覧に押し出されて消えていた
// (実測 2026-09-17)。

import XCTest
@testable import FTBridgeClient

final class XcodebuildFailureSummaryTests: XCTestCase {

    private let realError = "xcodebuild: error: Unable to find a device matching the provided destination specifier:"

    private func ineligibleDestinationLines(_ count: Int) -> [String] {
        (1...count).map {
            "\t\t{ platform:iOS Simulator, arch:arm64, id:UDID-\($0), OS:17.4, name:iPad \($0), "
                + "error:… doesn't match FleetestRunnerApp.app's iOS Simulator 18.0 deployment target … }"
        }
    }

    /// 本命: 原因行が一覧より前にあっても、一覧30行超に押し出されず残る
    func testTheRealErrorLineSurvivesALongIneligibleDestinationList() {
        let output = (["Test session results, code coverage, and logs:", realError]
            + ineligibleDestinationLines(40)).joined(separator: "\n")
        let summary = XcodebuildFailureSummary.summarize(output: output, tailLineCount: 30)
        XCTAssertTrue(summary.contains("Unable to find a device matching"), summary)
    }

    /// 対象外の宛先1件ぶんの行(`{ platform:…}`)は要約から消える
    func testIneligibleDestinationLinesAreRemoved() {
        let output = ([realError] + ineligibleDestinationLines(40)).joined(separator: "\n")
        let summary = XcodebuildFailureSummary.summarize(output: output, tailLineCount: 30)
        XCTAssertFalse(summary.contains("{ platform:"), summary)
    }

    /// 一覧の見出し行("Ineligible destinations for the …")も消える
    func testTheIneligibleDestinationsHeadingIsRemoved() {
        let output = [realError, "Ineligible destinations for the \"FleetestRunner\" scheme:"]
            .joined(separator: "\n")
        let summary = XcodebuildFailureSummary.summarize(output: output, tailLineCount: 30)
        XCTAssertFalse(summary.contains("Ineligible destinations"), summary)
    }

    /// error: を含む行が1つも無ければ、従来どおり単純な末尾(署名エラー等の既存経路は変えない)
    func testFallsBackToThePlainTailWhenNoErrorLineIsFound() {
        let output = ["line1", "line2", "line3", "line4"].joined(separator: "\n")
        let summary = XcodebuildFailureSummary.summarize(output: output, tailLineCount: 2)
        XCTAssertEqual(summary, "line3\nline4")
    }

    /// 原因行が末尾30行の中にも既に含まれていても、二重には出さない
    func testTheErrorLineIsNotDuplicatedWhenItIsAlsoInTheTail() {
        let output = ([realError] + (1...5).map { "trailing line \($0)" }).joined(separator: "\n")
        let summary = XcodebuildFailureSummary.summarize(output: output, tailLineCount: 30)
        let occurrences = summary.components(separatedBy: realError).count - 1
        XCTAssertEqual(occurrences, 1, summary)
        XCTAssertTrue(summary.contains("trailing line 5"), summary)
    }

    /// 上限(tailLineCount)は守る。原因行1本 + 一覧を除いた末尾で埋める
    func testTheResultIsBoundedByTailLineCount() {
        let output = ([realError] + (1...50).map { "log line \($0)" }).joined(separator: "\n")
        let summary = XcodebuildFailureSummary.summarize(output: output, tailLineCount: 10)
        XCTAssertEqual(summary.split(separator: "\n").count, 10)
        XCTAssertTrue(summary.contains(realError), summary)
        // 一覧を除いた「末尾」が続くので、直近の行(50 に近いもの)が残る
        XCTAssertTrue(summary.contains("log line 50"), summary)
    }
}
