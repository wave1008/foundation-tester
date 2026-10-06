// 外から受けた runID は results/runs の1階層に収まるものだけ通す(RunResultsStore.isSingleComponentRunID)。
// runDir は runID をそのままパスに足すので、`..` で results/ の外の run.json を読ませない。

import XCTest
import ArgumentParser
@testable import fleetest

final class ResultsRunIDValidationTests: XCTestCase {

    func testResultsRunRefusesARunIDThatWalksOutOfItsDirectory() {
        for runID in ["202609/../../x", "..", "."] {
            XCTAssertThrowsError(try ApiResultsRunCommand.parse(["--run-id", runID]), runID) {
                XCTAssertTrue(ApiResultsRunCommand.message(for: $0).contains("not a run ID"), ApiResultsRunCommand.message(for: $0))
            }
        }
        XCTAssertNoThrow(try ApiResultsRunCommand.parse(["--run-id", "20261006-104500Z-0a1b2c3d"]))
    }

    func testResultsCompareRefusesARunIDThatWalksOutOfItsDirectory() {
        XCTAssertThrowsError(try ApiResultsCompareCommand.parse(
            ["--previous-run-id", "20261006-104500Z-0a1b2c3d", "--latest-run-id", "2026/../../x"])) {
            XCTAssertTrue(ApiResultsCompareCommand.message(for: $0).contains("not a run ID"), ApiResultsCompareCommand.message(for: $0))
        }
        XCTAssertNoThrow(try ApiResultsCompareCommand.parse(
            ["--previous-run-id", "20261006-104500Z-0a1b2c3d", "--latest-run-id", "20261006-114500Z-4e5f6a7b"]))
    }
}
