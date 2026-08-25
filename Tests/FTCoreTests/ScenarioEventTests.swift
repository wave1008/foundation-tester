// NDJSON イベントの直列化。fleetest-scenarios(サブプロセス)→ ホスト(CLI/MCP)→ VSCode 拡張の
// 3者が行単位で読む唯一の経路で、ここが崩れると実行中の表示が丸ごと壊れる。
// これまで encodedLine/decode は FMHealthTests が fm フィールドのついでに1回通すだけだった。

import XCTest
@testable import FTCore

final class ScenarioEventTests: XCTestCase {

    // MARK: - 1行1イベントの不変条件

    /// **改行を含めない**。ユーザーの print が message に載る経路があり、改行が残ると
    /// ホストの行分割が1イベントを複数行と誤読してストリーム全体がズレる
    func testEncodedLineNeverContainsNewline() {
        var event = ScenarioEvent(kind: "log")
        event.message = "1行目\n2行目\r\n3行目"
        event.detail = "詳細\nの続き"
        let line = event.encodedLine()
        XCTAssertFalse(line.contains("\n"), "改行が残っている: \(line)")
        XCTAssertEqual(line.components(separatedBy: "\n").count, 1)
    }

    /// 1行に収める過程で**中身は失われない**。改行は JSON 文字列として `\n` にエスケープされる
    /// (エスケープ済みなので encodedLine 末尾の改行潰しには掛からない)ため、
    /// 複数行の print も欠落・改変なしにホストへ届く
    func testMultilineContentSurvivesRoundTripIntact() throws {
        var event = ScenarioEvent(kind: "log")
        event.message = "前\n後"
        let line = event.encodedLine()
        XCTAssertFalse(line.contains("\n"))
        let decoded = try XCTUnwrap(ScenarioEvent.decode(line: line))
        XCTAssertEqual(decoded.message, "前\n後")
    }

    func testRoundTripPreservesFields() throws {
        var event = ScenarioEvent(kind: "step")
        event.scenario = "ログイン.成功する"
        event.scene = 2
        event.section = "action"
        event.index = 7
        event.description = ##"tap "#ok""##
        event.status = "passed"
        event.durationMs = 1234
        event.snapshotMs = 90
        event.at = "2026-07-30T12:00:00.123Z"

        let decoded = try XCTUnwrap(ScenarioEvent.decode(line: event.encodedLine()))
        XCTAssertEqual(decoded.kind, "step")
        XCTAssertEqual(decoded.scenario, "ログイン.成功する")
        XCTAssertEqual(decoded.scene, 2)
        XCTAssertEqual(decoded.section, "action")
        XCTAssertEqual(decoded.index, 7)
        XCTAssertEqual(decoded.description, ##"tap "#ok""##)
        XCTAssertEqual(decoded.status, "passed")
        XCTAssertEqual(decoded.durationMs, 1234)
        XCTAssertEqual(decoded.snapshotMs, 90)
        XCTAssertEqual(decoded.at, "2026-07-30T12:00:00.123Z")
    }

    /// **nil はキーごと省略**。旧クライアントは知らないキーを読み飛ばすだけで済むが、
    /// null を明示すると型付きパーサ(拡張側 model.ts)が値ありとして扱いうる
    func testNilFieldsAreOmittedFromOutput() {
        let line = ScenarioEvent(kind: "ping").encodedLine()
        XCTAssertEqual(line, #"{"kind":"ping"}"#)
        XCTAssertFalse(line.contains("null"))
    }

    /// スラッシュをエスケープしない(レポートパスが `\/` だらけになると人もツールも読みにくい)
    func testPathsAreNotEscaped() {
        var event = ScenarioEvent(kind: "scenarioFinished")
        event.reportPath = "/tmp/reports/a.md"
        XCTAssertTrue(event.encodedLine().contains("/tmp/reports/a.md"))
    }

    /// キー順は安定(sortedKeys)。差分・ゴールデン比較が揺れないため
    func testKeyOrderIsDeterministic() {
        var event = ScenarioEvent(kind: "step")
        event.status = "passed"
        event.index = 1
        XCTAssertEqual(event.encodedLine(), #"{"index":1,"kind":"step","status":"passed"}"#)
    }

    // MARK: - 前方・後方互換

    /// 新しいプロデューサ → 旧コンシューマ相当。知らないキーがあっても落ちない
    func testDecodeIgnoresUnknownKeys() throws {
        let line = #"{"kind":"step","status":"passed","futureField":{"a":1}}"#
        let decoded = try XCTUnwrap(ScenarioEvent.decode(line: line))
        XCTAssertEqual(decoded.status, "passed")
    }

    /// 旧プロデューサ → 新コンシューマ。後発の optional が欠けていても落ちない
    func testDecodeToleratesMissingOptionalKeys() throws {
        let decoded = try XCTUnwrap(ScenarioEvent.decode(line: #"{"kind":"step"}"#))
        XCTAssertNil(decoded.durationMs)
        XCTAssertNil(decoded.worker)
    }

    /// kind が無い行は不正(必須キー)。壊れた行は nil を返し、呼び出し側が読み飛ばせること
    func testDecodeRejectsMalformedLines() {
        XCTAssertNil(ScenarioEvent.decode(line: ""))
        XCTAssertNil(ScenarioEvent.decode(line: "not json"))
        XCTAssertNil(ScenarioEvent.decode(line: #"{"status":"passed"}"#), "kind は必須")
        XCTAssertNil(ScenarioEvent.decode(line: #"{"kind":123}"#), "kind は文字列")
    }

    // MARK: - status 語彙

    /// status 文字列は拡張側 model.ts の StepStatus と同じ集合でなければならない
    /// (集合そのものの照合は vscode-fleetest/test/stepStatusSync.test.mjs)
    func testEventStatusVocabulary() {
        let locator = FlowLocator(id: "ok")
        XCTAssertEqual(StepResult.Status.passed.eventStatus.status, "passed")
        XCTAssertNil(StepResult.Status.passed.eventStatus.detail)
        XCTAssertEqual(StepResult.Status.passedViaFallback(locator).eventStatus.status,
                       "passedViaFallback")
        XCTAssertEqual(StepResult.Status.healed(locator).eventStatus.status, "healed")
        XCTAssertEqual(StepResult.Status.failed("理由").eventStatus.status, "failed")
        XCTAssertEqual(StepResult.Status.failed("理由").eventStatus.detail, "理由")
        XCTAssertEqual(StepResult.Status.skipped("前段が失敗").eventStatus.status, "skipped")
        XCTAssertEqual(StepResult.Status.skipped("前段が失敗").eventStatus.detail, "前段が失敗")
        XCTAssertEqual(StepResult.Status.inconclusive("no assertions").eventStatus.status, "inconclusive")
        XCTAssertEqual(StepResult.Status.inconclusive("no assertions").eventStatus.detail, "no assertions")
    }

    /// フォールバック・修復は「何で解決したか」を detail に残す(レポートの調査手がかり)
    func testFallbackAndHealCarryLocatorInDetail() throws {
        let locator = FlowLocator(id: "login_btn")
        let fallback = try XCTUnwrap(
            StepResult.Status.passedViaFallback(locator).eventStatus.detail)
        XCTAssertTrue(fallback.contains(locator.summary), fallback)
        let healed = try XCTUnwrap(StepResult.Status.healed(locator).eventStatus.detail)
        XCTAssertTrue(healed.contains(locator.summary), healed)
    }
}
