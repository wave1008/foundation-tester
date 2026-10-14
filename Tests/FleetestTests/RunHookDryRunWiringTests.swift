// dry-run では run 前後のスクリプト(run-setup.sh / run-teardown.sh)を撃たない。dry-run は dispatch.lock を取らないので、
// 撃つと走行中の run の依存サービスを run-teardown.sh が落としうる。run と api run は別々に持つ2実装なのでソースで固定する
// (`fleetest run` は dry-run 分岐で ProfileRunner.run の前に抜ける / `api run` は呼び出しを `!dryRun` で囲む)。

import XCTest

final class RunHookDryRunWiringTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testApiRunGuardsTheHookCallWithNotDryRun() throws {
        let lines = try source("Sources/fleetest/ApiRunCommand.swift").components(separatedBy: "\n")
        let calls = lines.indices.filter { lines[$0].contains("RunHookRunner.begin(") }
        XCTAssertEqual(calls.count, 1, "expected exactly one RunHookRunner.begin call in ApiRunCommand")
        for call in calls {
            guard let guardLine = lines[..<call].lastIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("if ")
            }) else { return XCTFail("RunHookRunner.begin must sit inside an if") }
            XCTAssertTrue(lines[guardLine].contains("!dryRun"),
                          "the if around RunHookRunner.begin must exclude dry-run: \(lines[guardLine])")
        }
    }

    func testRunReturnsFromTheDryRunBranchBeforeProfileRunner() throws {
        let text = try source("Sources/fleetest/Fleetest.swift")
        guard let branch = text.range(of: "if dryRun {"),
              let profileRun = text.range(of: "ProfileRunner(") ?? text.range(of: "ProfileRunner.run(")
        else { return XCTFail("dry-run branch or ProfileRunner call not found in Fleetest.swift") }
        XCTAssertLessThan(branch.lowerBound, profileRun.lowerBound,
                          "the dry-run branch must come before the ProfileRunner call (it runs the hooks)")
    }
}
