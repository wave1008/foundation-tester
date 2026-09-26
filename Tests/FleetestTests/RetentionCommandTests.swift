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

    /// 最小値未満は断る(0 も含む)。ちょうど最小値・null(既定へ戻す)・キー欠落は通す
    func testImportBelowTheMinimumIsRejected() throws {
        func validate(_ json: String) throws {
            try ApiRetentionCommand.validateMinimums(try ApiRetentionCommand.decode(json))
        }
        for json in [#"{"deviceCapturesMaxBytes":1073741823}"#, #"{"recordingsMaxBytes":2147483647}"#,
                     #"{"reportsMaxBytes":104857599}"#, #"{"logsMaxBytes":10485759}"#,
                     #"{"xcresultMaxBytes":1073741823}"#, #"{"logsMaxBytes":0}"#] {
            XCTAssertThrowsError(try validate(json), json)
        }
        XCTAssertNoThrow(try validate(#"{"deviceCapturesMaxBytes":1073741824,"recordingsMaxBytes":2147483648,"reportsMaxBytes":104857600,"logsMaxBytes":10485760,"xcresultMaxBytes":1073741824}"#))
        XCTAssertNoThrow(try validate(#"{"logsMaxBytes":null,"sweepAfterRun":false}"#))
    }

    /// 全欄が既定へ戻ったら retention 欄ごと消す(既定だけの設定を残さない)
    func testResettingEveryFieldRemovesThePolicy() throws {
        let current = RetentionPolicy(logsMaxBytes: 5)
        XCTAssertNil(try merge(current, #"{"logsMaxBytes":null}"#))
    }

    /// xcresult も他の上限4欄と同じ3値(欠落/null/値)で合流する
    func testXcresultMaxBytesIsMergedLikeTheOtherByteCaps() throws {
        let current = RetentionPolicy(xcresultMaxBytes: 10)
        XCTAssertEqual(try merge(current, #"{"xcresultMaxBytes":99}"#)?.xcresultMaxBytes, 99)
        XCTAssertNil(try merge(current, #"{"xcresultMaxBytes":null}"#)?.xcresultMaxBytes)
        XCTAssertEqual(try merge(current, #"{}"#)?.xcresultMaxBytes, 10, "キー無しは据え置く")
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

    func testXcresultFlagSelectsOnlyXcresult() {
        XCTAssertEqual(
            CleanCommand.categories(recordings: false, reports: false, logs: false,
                                    deviceCaptures: false, xcresult: true),
            [.xcresult])
    }

    // MARK: - レポートのファイル名から日付を取る

    func testReportDayIsTakenFromTheScenarioFileNameStamp() {
        XCTAssertEqual(
            RetentionSweeper.reportDay(of: "scenario-20260723-024446-308-セレクタ_S0010.md"),
            "20260723")
        XCTAssertEqual(
            RetentionSweeper.reportDay(of: "scenario-20260723-024446-308-x-scene1-step2-y.png"),
            "20260723")
        // 失敗の証跡はレポートの名前から導く(FailureEvidence.url)= 同じ日へ束ねて消える
        let report = URL(fileURLWithPath: "/r/scenario-20260723-024446-308-セレクタ_S0010.md")
        XCTAssertEqual(
            RetentionSweeper.reportDay(of: FailureEvidence.url(forReport: report).lastPathComponent),
            "20260723")
    }

    /// この形でないファイルには触らない(利用者が置いた別のファイルかもしれない)
    func testFilesWithoutTheStampAreOutOfScope() {
        XCTAssertNil(RetentionSweeper.reportDay(of: "README.md"))
        XCTAssertNil(RetentionSweeper.reportDay(of: "scenario-2026-07-23-024446-308-x.md"))
        XCTAssertNil(RetentionSweeper.reportDay(of: "scenario-20260723-0244-308-x.md"))
        XCTAssertNil(RetentionSweeper.reportDay(of: "my-scenario-20260723-024446-308-x.md"))
    }

    /// `configured` は明示した欄だけ値・未設定は null で、**全キーを必ず出す**(拡張は null を
    /// 空欄 + プレースホルダにする)。`policy` 側は未設定も既定で埋めた実効値のまま
    func testConfiguredCarriesOnlyExplicitValuesAndNullsTheRest() throws {
        let line = try XCTUnwrap(ApiRetentionCommand.outputLine(
            policy: RetentionPolicy(logsMaxBytes: 7, sweepAfterRun: true), usage: nil))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let configured = try XCTUnwrap(json["configured"] as? [String: Any])
        XCTAssertEqual(Set(configured.keys), [
            "deviceCapturesMaxBytes", "recordingsMaxBytes", "reportsMaxBytes", "logsMaxBytes",
            "xcresultMaxBytes", "sweepAfterRun",
        ])
        XCTAssertEqual(configured["logsMaxBytes"] as? Int, 7)
        XCTAssertEqual(configured["sweepAfterRun"] as? Bool, true)
        XCTAssertTrue(configured["recordingsMaxBytes"] is NSNull)
        let policy = try XCTUnwrap(json["policy"] as? [String: Any])
        XCTAssertEqual(policy["recordingsMaxBytes"] as? Int, 53_687_091_200)
        let minimums = try XCTUnwrap(json["minimums"] as? [String: Any])
        XCTAssertEqual(minimums["reportsMaxBytes"] as? Int, 104_857_600)
        XCTAssertEqual(minimums.count, 5, "上限5欄すべて")
    }
}
