import Foundation
import XCTest

/// per-scenario 集計(`scenarioSummary` / `flakyScenarios`)の窓は呼び手ごとに違う ——
/// ダッシュボード(`api results`)は直近 `recentScenarioRunsWindow` 回へ絞り、CLI の
/// `results summary` / `results flaky` は `--since` の窓をそのまま出す(`.max`)。
/// **どちらも緑のまま入れ替えられる**(型は Int しか見ない)ので、「2経路を1つに寄せる」
/// 変更で CLI の出力が黙って変わるのをここで止める。
final class ScenarioSummaryWindowWiringTests: XCTestCase {

    private static func source(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent(relativePath)
    }

    /// コメント(`//` より右)を落とした本文。呼び出しが折り返されても拾えるよう全文へ正規表現をかける
    private static func codeOnly(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//")[0] }
            .joined(separator: "\n")
    }

    private static func callArguments(in code: String, function: String) throws -> [String] {
        let pattern = try NSRegularExpression(
            pattern: #"\#(function)\(([^)]*)\)"#, options: [.dotMatchesLineSeparators])
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return pattern.matches(in: code, range: range).map { match in
            String(code[Range(match.range(at: 1), in: code)!])
        }
    }

    private static let windowedFunctions = ["scenarioSummary", "flakyScenarios"]

    func testApiResultsNarrowsToTheRecentWindow() throws {
        let code = try Self.codeOnly(Self.source("Sources/fleetest/ApiResultsCommand.swift"))
        for function in Self.windowedFunctions {
            let calls = try Self.callArguments(in: code, function: function)
            XCTAssertEqual(calls.count, 1, "ApiResultsCommand の \(function) 呼び出しが1件ではない")
            XCTAssertTrue(calls[0].contains("recentRuns: RunResultsQuery.recentScenarioRunsWindow"),
                          "ダッシュボードは共通の窓(recentScenarioRunsWindow)で集計すること"
                          + "(\(function))。実際: \(calls[0])")
        }
    }

    func testCLIResultsKeepsTheWholeSinceWindow() throws {
        let code = try Self.codeOnly(Self.source("Sources/fleetest/ResultsCommand.swift"))
        for function in Self.windowedFunctions {
            let calls = try Self.callArguments(in: code, function: function)
            XCTAssertEqual(calls.count, 1, "ResultsCommand の \(function) 呼び出しが1件ではない")
            XCTAssertTrue(calls[0].contains("recentRuns: .max"),
                          "CLI の results \(function) は --since の窓をそのまま集計すること"
                          + "(窓を切ると --since の指定が部分的に効かなくなる)。実際: \(calls[0])")
        }
    }

    /// 呼び手が増えたら窓の選択を1件ずつ決めさせる(既定値が無いので渡し忘れは起きないが、
    /// 新しい経路がどちらを名乗ったかはここで目に入る)
    func testWindowedAggregatesHaveExactlyTwoCallSitesEach() throws {
        let sourcesDir = Self.source("Sources")
        for function in Self.windowedFunctions {
            var total = 0
            let enumerator = FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)!
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard url.lastPathComponent != "RunResultsQuery.swift" else { continue }  // 定義元
                total += try Self.callArguments(in: try Self.codeOnly(url), function: function).count
            }
            XCTAssertEqual(total, 2,
                           "\(function) の呼び手は api results と CLI の results の2つ。"
                           + "増えたならその経路の窓を決めて本数を更新する")
        }
    }
}
