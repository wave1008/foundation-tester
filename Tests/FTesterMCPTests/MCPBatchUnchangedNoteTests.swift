// ft_batch が「全手が成功したのに画面が1ピクセルも動いていない」を偽成功で終える件の対策
// (2026-08-12)。同一性判定は MCPServer.looksUnchanged を再利用する(ft_swipe の settle-lite —
// snapshotAfterBodyWithStatus — と同じ判定。2つ目を書かない)。ここは driver を要らない純関数
// MCPServer.batchUnchangedNote だけを対象にする(実行ループ全体は MCPBatchTests が見る)。

import XCTest
import FTCore
@testable import ftester_mcp

private func batchElement(ref: Int, id: String? = "row") -> ElementInfo {
    ElementInfo(ref: ref, type: "staticText", identifier: id, label: "label", value: nil,
               placeholder: nil, enabled: true,
               frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 1)
}

/// `marker` は looksUnchanged が見ない場所(truncatedCount)に置く目印。
/// どの SnapshotResponse インスタンスが最終的に選ばれたかを、要素を変えずに見分けるため
private func batchSnapshot(_ elements: [ElementInfo], marker: Int) -> SnapshotResponse {
    SnapshotResponse(sessionBundleID: "com.example.app",
                     screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                     elements: elements, truncatedCount: marker)
}

final class MCPBatchUnchangedNoteTests: XCTestCase {

    /// (1) 起点(バッチ開始前)と最終木が同一で、撮り直しても同一 → 注記が出る。
    /// 表示・記録に使う木は撮り直したほう(marker で確認)
    func testNoteAppearsWhenTheTreeIsIdenticalBeforeAndAfterTheBatchEvenAfterReRead() async throws {
        let before = batchSnapshot([batchElement(ref: 1)], marker: 0)
        let final = batchSnapshot([batchElement(ref: 1)], marker: 0)
        let reread = batchSnapshot([batchElement(ref: 1)], marker: 99)
        var rereadCalls = 0
        let (note, snapshot) = try await MCPServer.batchUnchangedNote(
            beforeBatch: before, final: final, stepCount: 3) {
            rereadCalls += 1
            return reread
        }
        XCTAssertFalse(note.isEmpty, "見分けが付かないのに何も言わないのは偽成功そのもの")
        XCTAssertFalse(note.contains("did not"), "断定しないこと(may/かもしれない止まり)")
        XCTAssertEqual(rereadCalls, 1, "見分けが付かないときだけ、1回だけ撮り直すこと")
        XCTAssertEqual(snapshot.truncatedCount, 99, "表示・記録は撮り直した木を使うこと")
    }

    /// (2) 起点と最終木が違う → 注記は出ない・撮り直しもしない(比較対象があるのに待たせない)
    func testNoteIsSilentWhenTheTreeActuallyChanged() async throws {
        let before = batchSnapshot([batchElement(ref: 1)], marker: 0)
        let final = batchSnapshot([batchElement(ref: 1), batchElement(ref: 2, id: "row2")], marker: 0)
        var rereadCalls = 0
        let (note, snapshot) = try await MCPServer.batchUnchangedNote(
            beforeBatch: before, final: final, stepCount: 3) {
            rereadCalls += 1
            return batchSnapshot([], marker: 99)
        }
        XCTAssertEqual(note, "")
        XCTAssertEqual(rereadCalls, 0, "変わっているのに撮り直すのは無駄待ち")
        XCTAssertEqual(snapshot.truncatedCount, 0, "final をそのまま返すこと")
    }

    /// (3) 起点が無い(nil。まだ ft_snapshot / snapshotAfter を撃っていない)→ 比較対象が無いので
    /// 何も言わない(snapshotAfterBody の beforeAction == nil と同じ規律)
    func testNoteIsSilentWhenThereIsNoBeforeBatchSnapshot() async throws {
        let final = batchSnapshot([batchElement(ref: 1)], marker: 0)
        var rereadCalls = 0
        let (note, snapshot) = try await MCPServer.batchUnchangedNote(
            beforeBatch: nil, final: final, stepCount: 3) {
            rereadCalls += 1
            return batchSnapshot([], marker: 99)
        }
        XCTAssertEqual(note, "")
        XCTAssertEqual(rereadCalls, 0)
        XCTAssertEqual(snapshot.truncatedCount, 0)
    }

    /// (4) 撮り直したら実は変わっていた → 「撮り直した」旨だけ言う(「どの手も効かなかったかも」
    /// ではない)。表示・記録は撮り直した木を使う
    func testNoteMentionsTheReReadOnlyWhenTheSecondCheckDiffers() async throws {
        let before = batchSnapshot([batchElement(ref: 1)], marker: 0)
        let final = batchSnapshot([batchElement(ref: 1)], marker: 0)
        let reread = batchSnapshot([batchElement(ref: 1), batchElement(ref: 2, id: "row2")], marker: 42)
        let (note, snapshot) = try await MCPServer.batchUnchangedNote(
            beforeBatch: before, final: final, stepCount: 1) { reread }
        XCTAssertTrue(note.contains("re-read once"), note)
        XCTAssertFalse(note.contains("none of the steps") || note.contains("actually changed"), note)
        XCTAssertEqual(snapshot.truncatedCount, 42)
    }
}
