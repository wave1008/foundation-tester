// `api retention --import` の合流(キー欠落 / null / 値の3値)と、`fleetest clean` の
// カテゴリ選択。どちらもデバイス・ファイルシステムに触らない純ロジック。

import XCTest
import FTCore
@testable import fleetest

final class RetentionCommandTests: XCTestCase {

    private func merge(_ current: RetentionPolicy?, _ json: String) throws -> RetentionPolicy? {
        ApiRetentionCommand.merge(current, with: try ApiRetentionCommand.decode(json))
    }

    /// **送られてきたキーだけ**を上書きし、無いキーは据え置く
    func testOnlyTheKeysPresentInTheImportAreOverwritten() throws {
        let current = RetentionPolicy(deviceCapturesMaxBytes: 10, recordingsMaxBytes: 20)
        let merged = try merge(current, #"{"recordingsMaxBytes":99}"#)
        XCTAssertEqual(merged?.deviceCapturesMaxBytes, 10)
        XCTAssertEqual(merged?.recordingsMaxBytes, 99)
    }

    /// null は「既定へ戻す」= 欄を消す。**キー欠落と同じにならない**
    func testNullResetsTheKeyToItsDefault() throws {
        let current = RetentionPolicy(deviceCapturesMaxBytes: 10, recordingsMaxBytes: 20)
        let merged = try merge(current, #"{"recordingsMaxBytes":null}"#)
        XCTAssertEqual(merged?.deviceCapturesMaxBytes, 10)
        XCTAssertNil(merged?.recordingsMaxBytes)
    }

    /// 0 は有効な指定なので欄として残る(null と混ぜない)
    func testZeroIsStoredAndIsNotTreatedAsAReset() throws {
        let merged = try merge(nil, #"{"logsMaxBytes":0}"#)
        XCTAssertEqual(merged?.logsMaxBytes, 0)
    }

    /// 全欄が既定へ戻ったら retention 欄ごと消す(既定だけの設定を残さない)
    func testResettingEveryFieldRemovesThePolicy() throws {
        let current = RetentionPolicy(logsMaxBytes: 5)
        XCTAssertNil(try merge(current, #"{"logsMaxBytes":null}"#))
    }

    func testSweepAfterRunIsMergedLikeTheByteCaps() throws {
        XCTAssertEqual(try merge(nil, #"{"sweepAfterRun":false}"#)?.sweepAfterRun, false)
        XCTAssertEqual(try merge(RetentionPolicy(sweepAfterRun: false), #"{}"#)?.sweepAfterRun, false)
        XCTAssertNil(try merge(RetentionPolicy(sweepAfterRun: false), #"{"sweepAfterRun":null}"#))
    }

    func testInvalidImportIsRejected() {
        XCTAssertThrowsError(try ApiRetentionCommand.decode("not json"))
        XCTAssertThrowsError(try ApiRetentionCommand.decode(#"{"logsMaxBytes":"big"}"#))
    }

    // MARK: - カテゴリ選択

    func testNoCategoryFlagsMeansEveryCategory() {
        XCTAssertEqual(
            CleanCommand.categories(recordings: false, reports: false, logs: false,
                                    deviceCaptures: false),
            RetentionSweeper.Category.allCases)
    }

    func testExplicitCategoriesAreTheOnlyOnesSwept() {
        XCTAssertEqual(
            CleanCommand.categories(recordings: true, reports: false, logs: true,
                                    deviceCaptures: false),
            [.recordings, .logs])
    }

    // MARK: - レポートのファイル名から日付を取る

    func testReportDayIsTakenFromTheScenarioFileNameStamp() {
        XCTAssertEqual(
            RetentionSweeper.reportDay(of: "scenario-20260723-024446-308-セレクタ_S0010.md"),
            "20260723")
        XCTAssertEqual(
            RetentionSweeper.reportDay(of: "scenario-20260723-024446-308-x-scene1-step2-y.png"),
            "20260723")
    }

    /// この形でないファイルには触らない(利用者が置いた別のファイルかもしれない)
    func testFilesWithoutTheStampAreOutOfScope() {
        XCTAssertNil(RetentionSweeper.reportDay(of: "README.md"))
        XCTAssertNil(RetentionSweeper.reportDay(of: "scenario-2026-07-23-024446-308-x.md"))
        XCTAssertNil(RetentionSweeper.reportDay(of: "scenario-20260723-0244-308-x.md"))
        XCTAssertNil(RetentionSweeper.reportDay(of: "my-scenario-20260723-024446-308-x.md"))
    }
}
