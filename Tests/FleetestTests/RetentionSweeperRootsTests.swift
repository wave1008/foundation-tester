// 掃除が見る2つの場所(`RetentionSweeper.Roots`)を、受け手の外部構成と同じ「別々の場所」で確かめる。
//
// **保守者のクローン構成では2つが同じ場所になるので、この取り違えは手元の実データでは出ない**
// (受け手の録画・レポートを1度も掃除していなかったのに、手元の確認は緑だった)。
// だからテストは必ず2つを別の一時フォルダに置く。

import XCTest
@testable import fleetest

final class RetentionSweeperRootsTests: XCTestCase {

    private var package: URL!
    private var tool: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-roots-\(UUID().uuidString)", isDirectory: true)
        package = base.appendingPathComponent("work", isDirectory: true)
        tool = base.appendingPathComponent("foundation-tester", isDirectory: true)
        let fm = FileManager.default
        // 受け手のパッケージ: プロジェクトのレポートと、install.sh のログ
        try fm.createDirectory(at: package.appendingPathComponent("TestProjects/app/reports"),
                               withIntermediateDirectories: true)
        try Data("r".utf8).write(to: package.appendingPathComponent(
            "TestProjects/app/reports/scenario-20260101-120000-000-x.md"))
        try fm.createDirectory(at: package.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
        try Data("i".utf8).write(to: package.appendingPathComponent(".fleetest/install-20260101.log"))
        // ツールのクローン: ブリッジのログ
        try fm.createDirectory(at: tool.appendingPathComponent(".fleetest"), withIntermediateDirectories: true)
        try Data("b".utf8).write(to: tool.appendingPathComponent(".fleetest/bridge-9999.log"))
        addTeardownBlock { try? fm.removeItem(at: base) }
    }

    /// レポートは**パッケージ側**から拾う(ツール側には TestProjects が無い)
    func testReportsComeFromThePackageRoot() {
        let roots = RetentionSweeper.Roots(package: package, tool: tool)
        let sessions = RetentionSweeper.sessions(for: .reports, roots: roots, activeRunID: nil)
        XCTAssertEqual(sessions.count, 1, "受け手のプロジェクトのレポートを拾っていない")
        // 一時フォルダの /var は /private/var の別名なので、実体のパスで比べる
        let found = sessions.first?.paths.first?.resolvingSymlinksInPath().path ?? ""
        XCTAssertTrue(found.hasPrefix(package.resolvingSymlinksInPath().path), found)
    }

    /// ログは**両方**から拾う(ブリッジのログはツール側・install.sh のログはパッケージ側)
    func testLogsComeFromBothStateDirectories() {
        let roots = RetentionSweeper.Roots(package: package, tool: tool)
        let names = Set(RetentionSweeper.sessions(for: .logs, roots: roots, activeRunID: nil)
            .flatMap(\.paths).map(\.lastPathComponent))
        XCTAssertEqual(names, ["bridge-9999.log", "install-20260101.log"])
    }

    /// 2つが同じ場所なら `.fleetest/` は1つだけ見る(同じログを2回数えない)
    func testSameRootIsScannedOnce() {
        let roots = RetentionSweeper.Roots(package: tool, tool: tool)
        XCTAssertEqual(roots.stateDirs.count, 1)
        XCTAssertEqual(RetentionSweeper.sessions(for: .logs, roots: roots, activeRunID: nil).count, 1)
    }
}
