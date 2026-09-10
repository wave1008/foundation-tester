// RunOrchestrator が recordingFinalizing を出す時点の判定(TestingSlots)と、その配線。
// 拡張はこのイベントから録画タブへ移るまで「録画を編集中」を出すので、早すぎると
// テスト中に出て、出し忘れると待ち時間に何も出ない(どちらも run の合否は変わらず緑のまま通る)。

import XCTest
@testable import FTCore

final class TestingSlotsTests: XCTestCase {

    func testAnnouncesOnceWhenTheLastSlotClosesAfterRecordingStarted() async {
        let slots = TestingSlots()
        await slots.open()  // 参加待ちの枠
        await slots.open()  // ワーカー A
        await slots.open()  // ワーカー B
        await slots.noteRecordingStarted()
        let admission = await slots.close()
        let a = await slots.close()
        let b = await slots.close()
        XCTAssertEqual([admission, a, b], [false, false, true])
    }

    /// 参加待ちの枠が開いている間は、先に参加したワーカーが全部終えても 0 を踏まない
    func testAdmissionSlotHoldsTheAnnouncementUntilLateWorkersJoin() async {
        let slots = TestingSlots()
        await slots.open()  // 参加待ちの枠
        await slots.open()  // 先に参加した Android
        await slots.noteRecordingStarted()
        let early = await slots.close()
        XCTAssertFalse(early, "遅延参加の iOS がまだ来ていない")
        await slots.open()  // 遅れて参加した iOS
        let admission = await slots.close()
        XCTAssertFalse(admission)
        let late = await slots.close()
        XCTAssertTrue(late)
    }

    func testNeverAnnouncesWithoutARecording() async {
        let slots = TestingSlots()
        await slots.open()
        await slots.open()
        _ = await slots.close()
        let last = await slots.close()
        XCTAssertFalse(last, "録画を1本も開始できなかった run では出さない")
    }

    /// 閉じる箇所の本数と順序: 参加待ちの枠 1 + 完了経路 1 + 復帰を諦める経路 2。完了経路は
    /// **切り出し(stopRecording)より前**に閉じる —— 後だと最後のワーカーの切り出しが終わるまで出ない
    func testEverySlotExitPathClosesAndTheCompletedPathClosesBeforeExtraction() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/RunOrchestrator.swift")
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let closes = lines.indices.filter { lines[$0] == "await closeTestingSlot()" }
        XCTAssertEqual(closes.count, 4, "スロットを閉じる経路の本数が変わった —— 各スロットがちょうど1回閉じるか見直すこと")
        guard let completed = lines.firstIndex(of: "return .completed(failed)") else {
            return XCTFail("runWorker の完了経路が見つからない(走査の前提が崩れた)")
        }
        XCTAssertEqual(lines[completed - 1], "await stopRecording(worker, leaseKey: leaseKey)")
        XCTAssertTrue(closes.contains(completed - 2), "完了経路で切り出しの直前に閉じていない")
    }
}
