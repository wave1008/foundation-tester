// `--limit` は1以上(0 以下は黙って空の一覧になる)。results list / slow と api results が同じ検査を通る。
// パッケージの外で打ったときは「ビルドに失敗」と言わない(results 等のビルドと無関係なコマンドも通る入口)

import XCTest
import ArgumentParser
@testable import fleetest
@testable import FTCore

final class ResultsLimitValidationTests: XCTestCase {

    func testNegativeAndZeroLimitsAreRefused() {
        XCTAssertThrowsError(try ResultsListCommand.parse(["--limit=-5"]))
        XCTAssertThrowsError(try ResultsListCommand.parse(["--limit=0"]))
        XCTAssertThrowsError(try ResultsSlowCommand.parse(["--limit=-1"]))
        XCTAssertThrowsError(try ApiResultsCommand.parse(["--limit=-5"]))
    }

    func testPositiveLimitIsAccepted() {
        XCTAssertNoThrow(try ResultsListCommand.parse(["--limit=3"]))
    }

    func testMissingPackageRootDoesNotSayTheBuildFailed() {
        let message = ScenarioHostError.packageRootNotFound.errorDescription ?? ""
        XCTAssertFalse(message.contains("failed to build"), message)
        XCTAssertTrue(message.contains("Package.swift not found"), message)
    }
}
