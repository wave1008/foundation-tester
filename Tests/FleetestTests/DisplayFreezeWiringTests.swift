// 境目の表示の確認(DisplayFreezeWatch)が run の 2 実装(run / api run)に届くことを固定する。
// 配線は ProfileRunOrchestrator.make の 1 箇所(RunOrchestrator.checkLaneDisplay)。未注入は合法なので
// コンパイルでは止まらない = 走査で固定する

import XCTest

final class DisplayFreezeWiringTests: XCTestCase {

    private static func code(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheSharedWiringPassesTheLaneDisplayCheck() throws {
        let text = try Self.code("Sources/fleetest/ProfileRunOrchestrator.swift")
        XCTAssertTrue(text.contains("checkLaneDisplay: {"), "ProfileRunOrchestrator.make が checkLaneDisplay を渡していない")
        XCTAssertTrue(text.contains("DisplayFreezeWatch.production("), "本番の DisplayFreezeWatch を使っていない")
    }

    func testTheOrchestratorConsultsTheCheckAfterEveryScenario() throws {
        let text = try Self.code("Sources/FTCore/RunOrchestrator.swift")
        XCTAssertEqual(text.components(separatedBy: "await checkLaneDisplay(").count - 1, 1)
        // 確定したレーンは .frozen と同じ離脱(直前の結果を捨てて振り直し)を通り、上限では成功の記録を失敗へ書き換える
        XCTAssertTrue(text.contains("reason: \"a frozen display (\\(displayFreeze.detail))\", cause: .frozen"))
        XCTAssertTrue(text.contains("invalidatesPassedRecord: outcome == .passed"))
        XCTAssertTrue(text.contains("recorder?.markLastFailed("))
        // 録画の合否は確認の後に決める(確認より前に passed を渡さない)
        let check = text.range(of: "await checkLaneDisplay(")!
        let video = text.range(of: "await videoRecording?.scenarioFinished(")!
        XCTAssertLessThan(check.lowerBound, video.lowerBound, "録画へ合否を渡すのは表示の確認の後")
        // 終了イベントは確認まで保留し、確認の後に(凍結なら失敗として)流す
        XCTAssertTrue(text.contains("heldFinish.withLock { $0 = (event, at) }"), "終了イベントを保留していない")
        let release = text.range(of: "Self.failedFinish(held.event)")!
        XCTAssertTrue(text.contains("continuation.yield(.flowEndedAt(worker: heldWorker, flowURL: heldURL, at: held.at))"),
                      "保留した終了イベントの実際の終了時刻を所要の集計へ運んでいない")
        XCTAssertTrue(text.contains("continuation.yield(.flowStartedAt(worker: worker, flowURL: flowURL, at: Date()))"),
                      "開始も送った時刻で運ぶ(片方だけ送り手の時刻にすると所要が負になる)")
        XCTAssertLessThan(check.lowerBound, release.lowerBound, "保留した終了イベントを流すのは確認の後")
        XCTAssertTrue(text.contains("Self.restoreAppID(declared: item.info.app"), "前面へ戻すアプリはシナリオの宣言が先")
    }
}
