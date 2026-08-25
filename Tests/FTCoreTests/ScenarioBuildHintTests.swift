// ビルド失敗に添える「次の一手」。
//
// SPM の `invalid custom path` は正確だが**規約を知らない**ので、受け手は原因
// (2026-08-05 の `Projects/`→`TestProjects/` 改名の取り残し)に辿り着けない
// (外部フィードバック 2026-08-06)。直すのは `fleetest project sync` の1手。

import XCTest
@testable import FTCore

final class ScenarioBuildHintTests: XCTestCase {

    private func project() throws -> TestProject {
        let root = URL(fileURLWithPath: "/tmp/ft-hint-test")
        return TestProject(name: "MyAppTests", rootURL: root.appendingPathComponent("TestProjects/MyAppTests"))
    }

    func testHintNamesTheCurrentPathAndTheFix() throws {
        let tail = "error: invalid custom path 'Projects/MyAppTests/Scenarios' for target 'x'"
        let hint = ScenarioHost.buildHint(tail, project: try project())
        XCTAssertTrue(hint.contains("TestProjects/MyAppTests/scenarios"), "正しいパスを示すこと")
        XCTAssertTrue(hint.contains("fleetest project sync"), "直し方を示すこと")
    }

    /// **無関係な失敗に助言を出さない**(誤誘導は無いより悪い)
    func testNoHintForOtherBuildFailures() throws {
        let tail = "error: cannot find 'tapp' in scope"
        XCTAssertEqual(ScenarioHost.buildHint(tail, project: try project()), "")
    }
}
