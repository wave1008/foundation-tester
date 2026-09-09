// 打ち切られたステップの**所要時間**が結果 JSON に載ることのソース走査。
//
// `FTSync.run` が期限で打ち切ると outcome は nil = StepExecutor の計時ごと失われる。
// `durationMs: outcome?.timing?.durationMs` に戻しても**コンパイルは通り、テストも緑のまま**
// (欄が nil になるだけ)で、しかも落とすのは**いちばん高いステップ(コマンド上限まるごと)**
// なので、scenes[].durationMs も静かにその分を落とす。2026-09-09 の results DB では
// `the command timed out` の 10 件すべてが durationMs 無しだった。
// 同型: CommandNamePlumbingTests(command:)。

import XCTest
@testable import FTCore

final class TimeoutStepDurationPlumbingTests: XCTestCase {

    private var runtimeSource: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // FTCoreTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // リポジトリルート
            return try String(contentsOf: root.appendingPathComponent("Sources/FTDSL/FTRuntime.swift"),
                              encoding: .utf8)
        }
    }

    /// 打ち切り時にホスト側の実測へ落ちる代替が残っていること
    func testTimeoutPathFallsBackToTheHostMeasuredDuration() throws {
        let source = try runtimeSource
        XCTAssertTrue(source.contains("outcome?.timing?.durationMs\n            ?? continuousClockMilliseconds("),
                      "打ち切り時の durationMs がホスト実測へ落ちていない(FTRuntime.perform)")
        XCTAssertTrue(source.contains("let recordedAt = outcome?.at ?? "),
                      "打ち切り時の at が埋まっていない(FTRuntime.perform)")
    }

    /// 実行ステップの記録が**素の** `outcome?.timing?.durationMs` / `outcome?.at` に戻っていないこと
    func testExecutedStepIsNotRecordedWithTheRawOptionalTiming() throws {
        let source = try runtimeSource
        XCTAssertFalse(source.contains("durationMs: outcome?.timing?.durationMs,"),
                       "recordStep が素の optional を渡している(打ち切り時に時間が消える)")
        XCTAssertFalse(source.contains("at: outcome?.at,"),
                       "recordStep が素の optional を渡している(打ち切り時に時刻が消える)")
    }

    /// **埋めてよいのは外から見える2つだけ**。打ち切られた側にしか無い内訳を捏造しない
    /// (CLAUDE.md「言えないときは欄ごと省く」)
    func testBreakdownFieldsStayOptional() throws {
        let source = try runtimeSource
        for field in ["snapshotMs", "actionMs", "waitMs"] {
            XCTAssertTrue(source.contains("\(field): outcome?.timing?.\(field),"),
                          "\(field) は打ち切り時に nil のまま残すこと(内訳は外から測れない)")
        }
    }
}
