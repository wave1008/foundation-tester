// 実行ログ(events/*.ndjson)の ScenarioHost.run 側の配線ゲート。書き手そのものは
// ScenarioEventLogTests が見るが、「stdout/stderr の行を書き手へ流す呼び出し」「記録の確定後に
// rename する呼び出し」が消える変異はコンパイラでは止まらず、run は緑のまま実行ログだけが黙って
// 欠ける(.inflight のまま残る)ので、ソースを読んで固定する(FirstFrameGateWiringTests と同型)。

import XCTest

final class ScenarioEventLogWiringTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/FTCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // リポジトリ直下

    private func compactHostSource() throws -> String {
        let text = try String(contentsOf: Self.repoRoot
            .appendingPathComponent("Sources/FTCore/ScenarioHost.swift"), encoding: .utf8)
        return text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// 子の stdout の生の行・stderr の行がどちらも書き手へ流れていること
    func testChildOutputFlowsIntoTheEventLog() throws {
        let text = try compactHostSource()
        XCTAssertEqual(occurrences(of: "eventLog?.appendStdout(line)", in: text), 1,
                       "子の stdout の行を実行ログへ書く呼び出しが無い(または二重)")
        XCTAssertEqual(occurrences(of: "eventLog?.appendStderr(line)", in: text), 1,
                       "子の stderr の行を実行ログへ書く呼び出しが無い(または二重)")
    }

    /// 記録を書く3経路(起動前の中止・タイムアウト・通常終了)すべてで、record の戻り値の
    /// ファイル名で rename していること。1つ欠けるとその経路の実行ログだけ .inflight のまま残る
    func testEveryRecordSiteFinishesTheEventLog() throws {
        let text = try compactHostSource()
        let recordSites = occurrences(of: "letfileName=recording.recorder.record(", in: text)
        XCTAssertEqual(recordSites, 3, "記録を書く経路の数が変わった(このテストの前提を見直す)")
        XCTAssertEqual(occurrences(of: "eventLog?.finish(fileBase:fileName)", in: text), recordSites,
                       "記録を書く経路の数と、実行ログを確定させる呼び出しの数が一致しない")
    }
}
