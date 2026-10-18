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
            guard let guardLine = Self.enclosingIf(of: call, in: lines)
            else { return XCTFail("RunHookRunner.begin must sit inside an if") }
            XCTAssertTrue(lines[guardLine].contains("!dryRun"),
                          "the if around RunHookRunner.begin must exclude dry-run: \(lines[guardLine])")
        }
    }

    /// 呼び出しを**囲む**最も内側の `if`(波括弧の入れ子で数える。`do {` 等の if 以外の塊は外へたどる)。
    /// 直前にあるだけの別の if(計測の分岐など)を囲みと取り違えない
    static func enclosingIf(of index: Int, in lines: [String]) -> Int? {
        var depth = 0
        var i = index - 1
        while i >= 0 {
            let line = lines[i]
            depth += line.filter { $0 == "}" }.count - line.filter { $0 == "{" }.count
            if depth < 0 {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("if ") { return i }
                depth = 0
            }
            i -= 1
        }
        return nil
    }

    func testEnclosingIfSkipsASiblingIfAndADoBlock() {
        let lines = ["if ok, !dryRun {", "    if measuring {", "        x()", "    }", "    do {", "        call()", "    }", "}"]
        XCTAssertEqual(Self.enclosingIf(of: 5, in: lines), 0)
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
