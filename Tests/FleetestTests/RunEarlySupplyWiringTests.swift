// `fleetest run --profile` はビルドが要る回だけ、ビルドの前に準備の段(供給)を起こしてビルドと並行に進める。
// **型では守れない継ぎ目**: 準備の段をビルドの後へ動かしても、`early:` を渡し忘れても、緑のまま直列に戻る。

import XCTest

final class RunEarlySupplyWiringTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func code(_ path: String) throws -> [String] {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("//") }
    }

    func testRunPreparesTheSupplyBeforeTheBuildOnlyWhenTheBuildIsNeeded() throws {
        let lines = try code("Sources/fleetest/Fleetest.swift")
        func index(_ needle: String) -> Int? { lines.firstIndex { $0.contains(needle) } }
        let prepare = try XCTUnwrap(index("ProfileRunner.prepareSupply("), "run が準備の段を呼んでいない")
        let build = try XCTUnwrap(index("try ScenarioHost.build(project: testProject"), "走査がビルドの呼び出しに届いていない")
        XCTAssertLessThan(prepare, build, "準備の段がビルドの後にある(並行にならない)")
        // ビルドが要らない回は一覧の後に正確な本数で絞るので、門は buildNeeded。--failed は開始スクリプトを空撃ちしない
        let gate = try XCTUnwrap(lines[..<prepare].lastIndex { $0.hasPrefix("if let profile, !dryRun, !skipBuild") },
                                 "準備の段の門が無い")
        XCTAssertTrue(lines[gate].contains("ScenarioHost.buildNeeded(project: testProject)"), lines[gate])
        XCTAssertTrue(lines[gate].contains("!failed"), lines[gate])
        XCTAssertEqual(lines.filter { $0.contains("early: early.supply") }.count, 1, "ProfileRunner.run へ準備の段を渡していない")
    }

    /// 準備の段の片付けは、どの経路で抜けても供給のタスクを待ってから(defer の中では待てない)
    func testRunSettlesTheEarlySupplyOnEveryExit() throws {
        let lines = try code("Sources/fleetest/Fleetest.swift")
        let wrapper = try XCTUnwrap(lines.firstIndex { $0 == "func run() async throws {" })
        let body = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("private func runBody(earlySupply early:") })
        let between = lines[wrapper..<body]
        XCTAssertEqual(between.filter { $0.contains("await early.settleAndClose()") }.count, 2,
                       "本体の外側で、成功と失敗の両方の出口で片付けていない")
        XCTAssertFalse(lines.contains { $0.contains("defer") && $0.contains("early.") }, "defer で片付けている(待てない)")
    }
}
