// 失敗の証跡ファイル(書き手 = FTDSL の ScenarioReportWriter / 読み手 = fleetest-mcp)の置き場と往復。

import XCTest
@testable import FTCore

final class FailureEvidenceTests: XCTestCase {

    /// レポートの baseName を保つ(掃除はファイル名の `scenario-<日時>-` 接頭辞で日へ束ねる)
    func testEvidenceSitsNextToTheReportWithTheSameBaseName() {
        let report = URL(fileURLWithPath: "/tmp/r/scenario-20260925-101010-123-X_S0010.md")
        XCTAssertEqual(FailureEvidence.url(forReport: report).path,
                       "/tmp/r/scenario-20260925-101010-123-X_S0010.failure.json")
    }

    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("failure-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = dir.appendingPathComponent("scenario-20260925-101010-123-X_S0010.md")
        let evidence = FailureEvidence(scenes: [
            .init(number: 1, title: "t", elements: "[1] Text \"a\"", screenshotFile: "s.png",
                  screenshotBlank: false, foregroundWindows: ["w"], appProcess: []),
        ])
        try evidence.write(forReport: report)
        XCTAssertEqual(FailureEvidence.read(forReport: report), evidence)
    }

    /// 無い・壊れている証跡は nil(失敗の報告そのものは証跡なしで成り立つ)
    func testMissingOrBrokenEvidenceReadsAsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("failure-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = dir.appendingPathComponent("scenario-20260925-101010-123-X_S0010.md")
        XCTAssertNil(FailureEvidence.read(forReport: report))
        try Data("{not json".utf8).write(to: FailureEvidence.url(forReport: report))
        XCTAssertNil(FailureEvidence.read(forReport: report))
    }
}
