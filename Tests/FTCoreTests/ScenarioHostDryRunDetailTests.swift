// dry-run 失敗時の本文組み立て(ScenarioHost.dryRunFailureDetail)の検証。
// 実害(2026-07-28): 失敗理由は step イベントの detail に載るのに message(kind == log =
// 利用者の print 専用)だけを見ていたため、セレクタの構文エラーのように利用者が何も print
// しない失敗では `ftester api steps` が「dry-run が失敗しました」しか出さなかった
// (同じシナリオを ftester run で流すと本文が出るので、api steps だけ原因が読めなかった)。

import XCTest
@testable import FTCore

final class ScenarioHostDryRunDetailTests: XCTestCase {

    private func step(status: String, description: String?, detail: String?) -> ScenarioEvent {
        var event = ScenarioEvent(kind: "step")
        event.status = status
        event.description = description
        event.detail = detail
        return event
    }

    private func log(_ message: String) -> ScenarioEvent {
        var event = ScenarioEvent(kind: "log")
        event.message = message
        return event
    }

    /// 利用者が何も print しなくても、失敗ステップの detail が本文になる(本件の再発防止)
    func testFailedStepDetailIsSurfacedWithoutAnyLog() {
        let events = [
            step(status: "passed", description: "launch com.example", detail: nil),
            step(status: "failed", description: #"tap ".button&&idPrefix=x""#,
                 detail: #"セレクタの構文が不正です: 未知のフィルタ名 "idPrefix" です"#),
        ]
        let detail = ScenarioHost.dryRunFailureDetail(events)
        XCTAssertTrue(detail.contains("未知のフィルタ名"), "構文エラー本文が落ちてはいけない: \(detail)")
        XCTAssertTrue(detail.contains("idPrefix"), "どのセレクタかが分かること: \(detail)")
        XCTAssertNotEqual(detail, "dry-run が失敗しました")
    }

    /// ステップ説明を前置して「どの操作で落ちたか」が分かる
    func testDescriptionIsPrefixedToDetail() {
        let events = [step(status: "failed", description: "tap \"#foo\"", detail: "理由")]
        XCTAssertEqual(ScenarioHost.dryRunFailureDetail(events), "tap \"#foo\": 理由")
    }

    /// 説明が無い失敗は detail だけを出す(空の前置を作らない)
    func testDetailOnlyWhenDescriptionMissing() {
        let events = [step(status: "failed", description: nil, detail: "理由")]
        XCTAssertEqual(ScenarioHost.dryRunFailureDetail(events), "理由")
    }

    /// 利用者の print(kind == log)も従来どおり拾う。失敗 detail の後ろに続ける
    func testLogMessagesAreStillIncluded() {
        let events = [
            log("ユーザーの print"),
            step(status: "failed", description: "tap \"#foo\"", detail: "理由"),
        ]
        let detail = ScenarioHost.dryRunFailureDetail(events)
        XCTAssertTrue(detail.contains("理由"))
        XCTAssertTrue(detail.contains("ユーザーの print"))
    }

    /// 手がかりが1つも無いときだけ既定文言へ落ちる
    func testFallsBackWhenNothingToShow() {
        let events = [step(status: "passed", description: "tap \"#foo\"", detail: nil)]
        XCTAssertEqual(ScenarioHost.dryRunFailureDetail(events), "dry-run が失敗しました")
    }

    /// 大量の失敗でも末尾5件に収める(出力が溢れない)
    func testKeepsOnlyLastFiveEntries() {
        let events = (1...8).map { step(status: "failed", description: nil, detail: "理由\($0)") }
        let detail = ScenarioHost.dryRunFailureDetail(events)
        XCTAssertEqual(detail.split(separator: "\n").count, 5)
        XCTAssertTrue(detail.contains("理由8"))
        XCTAssertFalse(detail.contains("理由3"))
    }
}
