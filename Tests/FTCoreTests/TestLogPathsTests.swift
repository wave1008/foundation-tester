// `TestLog.directoryForLog` / `directoryForTemp` のパスの形と、run のフォルダ名(親・子・掃除の3者が共有)。

import XCTest
@testable import FTCore

final class TestLogPathsTests: XCTestCase {

    func testSessionLabelIsShiratesStyleLocalTime() throws {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 10, 7, 9, 5, 3)
        let date = try XCTUnwrap(Calendar.current.date(from: c))
        XCTAssertEqual(TestLogSessionLabel.label(date), "2026-10-07_090503")
    }

    func testDayIsReadOnlyFromTheLabelShape() {
        XCTAssertEqual(TestLogSessionLabel.day(ofLabel: "2026-10-07_090503"), "20261007")
        for other in ["2026-10-07", "my-notes", "2026-10-07_0905", "x2026-10-07_090503", "2026-10-07_090503x"] {
            XCTAssertNil(TestLogSessionLabel.day(ofLabel: other), other)
        }
    }

    /// Shirates と同じ単位: <reportDir>/<run の開始>/<テストクラス名>/
    func testLogDirectoryIsPerRunAndTestClass() {
        let url = TestLogPaths.logDirectory(reportDir: URL(fileURLWithPath: "/r"), runStartedAt: "2026-10-07_090503",
                                            className: "ログイン")
        XCTAssertEqual(url.path, "/r/2026-10-07_090503/ログイン")
        XCTAssertEqual(TestLogPaths.logDirectory(reportDir: URL(fileURLWithPath: "/r"), runStartedAt: "L",
                                                 className: "a/b:c").lastPathComponent, "a_b_c",
                       "区切りになる文字はフォルダ名1つに畳む")
        XCTAssertEqual(TestLogPaths.pathComponent(".."), "_")
        XCTAssertEqual(TestLogPaths.pathComponent(""), "_")
    }

    /// 一時フォルダはシナリオごとに一意(同じシナリオが並列に走っても衝突しない)
    func testTemporaryDirectoryIsUniquePerScenarioRun() {
        let base = URL(fileURLWithPath: "/t")
        let a = TestLogPaths.temporaryDirectory(base: base, scenarioID: "ログイン.S0010")
        let b = TestLogPaths.temporaryDirectory(base: base, scenarioID: "ログイン.S0010")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.deletingLastPathComponent().path, "/t")
        XCTAssertTrue(a.lastPathComponent.hasPrefix("ログイン.S0010-"), a.lastPathComponent)
    }

    /// 親が子へ run のフォルダ名を渡し、子が受ける(型の効かない子プロセス境界)
    func testTheRunLabelIsPassedToTheScenarioRunner() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/ScenarioHost.swift"), encoding: .utf8)
        XCTAssertTrue(host.contains("\"--run-started-at\", TestLogSessionLabel.processStart"))
        let main = try String(contentsOf: root.appendingPathComponent("Sources/FTScenarioRunner/ScenarioRunnerMain.swift"),
                              encoding: .utf8)
        XCTAssertTrue(main.contains("customLong(\"run-started-at\")"))
        XCTAssertTrue(main.contains("core.directoryForTemp = TestLogPaths.temporaryDirectory(base: TemporaryDirectory.url"),
                      "一時フォルダは子の TMPDIR の下(サンドボックスの中で書ける)")
        XCTAssertTrue(main.contains("try? FileManager.default.removeItem(at: temp)"), "シナリオの終わりに消す")
    }
}
