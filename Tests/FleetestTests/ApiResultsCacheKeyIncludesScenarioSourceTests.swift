// `fleetest api results`' output cache key did not depend on the scenario *source* tree
// (scenarios/ under TestProjects/<name>/), only on the results/ scan digest
// (RunResultsStore.scanFingerprint). But `insights`' `retiredScenarios` check depends on
// `definedScenarioClasses(of:)` → `ScenarioFolders.classFileMap(scenariosDir:)`, a source scan —
// deleting/renaming a scenario file did not invalidate the cache until the next run wrote new
// results, so `api results` kept returning stale insights while `--no-cache` already disagreed
// (contradicts the "no approximation" contract at the top of ResultsOutputCache.swift).
//
// The fix folds `ScenarioFolders.directorySignature(scenariosDir:)` — an existing, previously
// unused-in-production digest built exactly for "did the scenarios/ source tree change" — into
// ApiResultsCommand's cache key. `ScenarioFoldersTests.swift` already proves that digest reacts to
// added/removed/renamed scenario files; this test is a source-scan wiring check (same style as
// ScenarioSummaryWindowWiringTests.swift) confirming ApiResultsCommand actually threads the
// resulting digest into the `arguments:` array it hands to `ResultsOutputCache.argumentsKey(...)`
// — reverting to the old `arguments: [testProject.name, since, ...]` list (without the digest)
// makes this fail.

import Foundation
import XCTest

final class ApiResultsCacheKeyIncludesScenarioSourceTests: XCTestCase {

    private static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Sources/fleetest/ApiResultsCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private struct NotFound: Error {}

    /// `let <name> = ScenarioFolders.directorySignature(scenariosDir: ...)` の <name> を捕まえる
    private static func digestVariableName(in code: String) throws -> String {
        let pattern = #"let (\w+) = ScenarioFolders\.directorySignature\(scenariosDir:"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        guard let match = regex.firstMatch(in: code, range: range),
              let nameRange = Range(match.range(at: 1), in: code) else {
            XCTFail("ApiResultsCommand no longer computes a scenarios/ source digest via"
                + " ScenarioFolders.directorySignature")
            throw NotFound()
        }
        return String(code[nameRange])
    }

    /// `ResultsOutputCache.argumentsKey(arguments: [ ... ], executable: ...)` の `[ ... ]` の中身
    private static func argumentsArrayContents(in code: String) throws -> String {
        let pattern = #"ResultsOutputCache\.argumentsKey\(\s*arguments:\s*\[([^\]]*)\]"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        guard let match = regex.firstMatch(in: code, range: range),
              let contentsRange = Range(match.range(at: 1), in: code) else {
            XCTFail("ApiResultsCommand no longer builds the cache key via"
                + " ResultsOutputCache.argumentsKey(arguments: [...])")
            throw NotFound()
        }
        return String(code[contentsRange])
    }

    func testCacheKeyArgumentsIncludeTheScenarioSourceDigestVariable() throws {
        let code = try Self.source()
        let digestVariable = try Self.digestVariableName(in: code)
        let argumentsContents = try Self.argumentsArrayContents(in: code)
        XCTAssertTrue(argumentsContents.contains(digestVariable),
                      "scenarios/ の指紋(\(digestVariable))が argumentsKey の arguments へ渡っていない."
                      + " これが無いと C1(シナリオを消しても古い insights を返す)が再発する")
    }
}
