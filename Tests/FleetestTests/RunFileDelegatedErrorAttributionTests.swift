// `run-file --help` lists `--profile` and `--port` side by side, but combining them is
// rejected by RunScenarios.validate() (run-file delegates to RunScenarios.parse(arguments) to
// reuse the real `run` engine). Left unwrapped, RunScenarios.parse(_:) throws an error that
// ArgumentParser attributes to a *fresh, standalone* parse of RunScenarios (it is not part of the
// real `fleetest run-file …` invocation tree at all — see RunFileCommand.swift's comment), so the
// printed "Usage: run <options> / See 'run --help' …" banner names the wrong command. The fix
// (RunFileCommand.swift) catches whatever RunScenarios.parse(arguments) throws and re-throws a
// fresh ValidationError built only from the message text, discarding the borrowed identity — the
// same idiom already used for RunProfileSetOverride.parse in Fleetest.swift/ApiRunCommand.swift.
//
// A full run-file invocation needs a real TestProject + built scenario to reach this code path
// (device-independent, but still needs fixtures), so this is a source-scan contract test rather
// than a behavioral one — same style as ScenarioSummaryWindowWiringTests.swift.

import Foundation
import XCTest
@testable import fleetest

final class RunFileDelegatedErrorAttributionTests: XCTestCase {

    private static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Sources/fleetest/RunFileCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testDelegatedParseErrorIsCaughtAndRewrapped() throws {
        let code = try Self.source()
        guard let parseRange = code.range(of: "try RunScenarios.parse(arguments)") else {
            return XCTFail("RunFileCommand no longer delegates via RunScenarios.parse(arguments)")
        }
        // 呼び出しの直後(± 200 文字)に do/catch と ValidationError への詰め直しがあること。
        // 「素通し」に戻すと(= let command = try RunScenarios.parse(arguments) の1行に戻すと)落ちる
        let windowStart = code.index(parseRange.lowerBound,
                                      offsetBy: -200, limitedBy: code.startIndex) ?? code.startIndex
        let windowEnd = code.index(parseRange.upperBound,
                                    offsetBy: 200, limitedBy: code.endIndex) ?? code.endIndex
        let window = code[windowStart..<windowEnd]
        XCTAssertTrue(window.contains("do {"), "RunScenarios.parse の呼び出しが do/catch で囲われていない")
        XCTAssertTrue(window.contains("catch"), "RunScenarios.parse の呼び出しが do/catch で囲われていない")
        XCTAssertTrue(window.contains("ValidationError(RunScenarios.message(for: error))"),
                      "捕まえたエラーを ValidationError へ詰め直していない"
                      + "(素通しすると RunScenarios=`run` の Usage/help 案内が run-file の失敗に出る。"
                      + "localizedDescription で詰めると ArgumentParser の内部エラーの本文が消える)")
    }

    /// 詰め直しに使う文言は本文を保つ(localizedDescription だと ArgumentParser の内部エラーが
    /// 「The operation couldn't be completed.」に化ける)
    func testDelegatedParseErrorKeepsItsMessage() {
        do {
            _ = try RunScenarios.parse(["--no-such-flag"])
            XCTFail("an unknown flag must not parse")
        } catch {
            let message = RunScenarios.message(for: error)
            XCTAssertTrue(message.contains("no-such-flag"), message)
            XCTAssertFalse(message.contains("The operation couldn"), message)
        }
    }
}
