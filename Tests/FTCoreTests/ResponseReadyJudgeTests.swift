// t2 の判定(ResponseReadyJudge)。合成した木の履歴だけで、各分岐を落とす

import XCTest
@testable import FTCore

final class ResponseReadyJudgeTests: XCTestCase {

    private let used = FTRect(x: 10, y: 100, width: 100, height: 40)
    private let facts = ResponseInjectionFacts(firstDownTimeMs: 1000, lastDownTimeMs: 1100, injections: 2)

    private func element(_ label: String, frame: FTRect? = nil, enabled: Bool = true) -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: nil, label: label, value: nil, placeholder: nil,
                    enabled: enabled, frame: frame ?? used, depth: 1)
    }

    private func tree(at readIndex: Int, _ elements: [ElementInfo]) -> ResponseObservation.Tree {
        ResponseObservation.Tree(readIndex: readIndex, snapshot: SnapshotResponse(
            sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
            elements: elements, truncatedCount: 0))
    }

    /// 読みは 1200ms から 10ms 刻み(所要 4ms)。`ok` で読めなかった回を指定する
    private func observation(reads count: Int, failing: Set<Int> = [], startingAt start: Int = 1200,
                             trees: [ResponseObservation.Tree], endReason: String? = "nextInjection",
                             truncated: Bool? = nil, found: Bool = true) -> ResponseObservation {
        let reads = (0..<count).map {
            ResponseObservation.Read(startMs: start + $0 * 10, endMs: start + $0 * 10 + 4, ok: !failing.contains($0))
        }
        return ResponseObservation(found: found, firstDownTimeMs: 1000, lastDownTimeMs: 1100, injections: 2,
                                   endedAtMs: start + count * 10, endReason: endReason, reads: reads, trees: trees,
                                   truncated: truncated)
    }

    private func judge(_ observation: ResponseObservation, usedFrame: FTRect? = nil) -> ResponseReadyUpdate {
        ResponseReadyJudge.judge(
            observation: observation, facts: facts,
            resolve: { $0.elements.first { $0.label == "OK" } },
            isOccluded: { _, snapshot in snapshot.elements.contains { $0.label == "cover" } },
            usedFrame: usedFrame ?? used)
    }

    func testTargetAppearsLate() {
        let result = judge(observation(reads: 6, trees: [
            tree(at: 0, [element("other")]),
            tree(at: 3, [element("OK")]),
        ]))
        // 3 回目の読み(1230..1234)で揃い、4 回目も揃う → t2 = 1234
        XCTAssertEqual(result.readyMs, 234)
        XCTAssertEqual(result.readyAfterLastInjectionMs, 134)
        XCTAssertEqual(result.injectionSpanMs, 100)
        XCTAssertEqual(result.injections, 2)
        XCTAssertEqual(result.readyDecidedBy, "tree")
        XCTAssertEqual(result.readyIdentity, "locator")
        XCTAssertNil(result.readyMissing)
    }

    func testPresentButOccludedFirst() {
        let result = judge(observation(reads: 8, trees: [
            tree(at: 0, [element("OK"), element("cover")]),
            tree(at: 4, [element("OK")]),
        ]))
        XCTAssertEqual(result.readyMs, 1240 + 4 - 1000)
        XCTAssertNil(result.readyMissing)
    }

    func testFrameMovesThenSettlesAtTheUsedFrame() {
        let moving = FTRect(x: 10, y: 160, width: 100, height: 40)
        let result = judge(observation(reads: 8, trees: [
            tree(at: 0, [element("OK", frame: moving)]),
            tree(at: 2, [element("OK", frame: FTRect(x: 10, y: 130, width: 100, height: 40))]),
            tree(at: 5, [element("OK")]),
        ]))
        XCTAssertEqual(result.readyMs, 1250 + 4 - 1000)
    }

    func testDisabledTargetIsNotReady() {
        let result = judge(observation(reads: 6, trees: [
            tree(at: 0, [element("OK", enabled: false)]),
            tree(at: 3, [element("OK")]),
        ]))
        XCTAssertEqual(result.readyMs, 1230 + 4 - 1000)
    }

    func testSingleReadWithoutConfirmingReadIsNotReady() {
        let result = judge(observation(reads: 4, trees: [
            tree(at: 0, [element("other")]),
            tree(at: 3, [element("OK")]),
        ]))
        XCTAssertNil(result.readyMs)
        XCTAssertEqual(result.readyMissing, "notReadyBeforeNextAction")
        XCTAssertEqual(result.injections, 2)
        XCTAssertEqual(result.injectionSpanMs, 100)
    }

    func testConditionThatBreaksOnTheNextReadIsNotStable() {
        // 読み 0 で揃い、読み 1 で崩れ(覆われる)、読み 2・3 で再び揃う → t2 は読み 2 の終わり(読み 0 は確認が取れない)
        let result = judge(observation(reads: 4, trees: [
            tree(at: 0, [element("OK")]),
            tree(at: 1, [element("OK"), element("cover")]),
            tree(at: 2, [element("OK")]),
        ]))
        XCTAssertEqual(result.readyMs, 1220 + 4 - 1000)
    }

    func testFailedReadsAreSkippedAndTheNextSuccessfulReadConfirms() {
        // 読み 1 は読めなかった: 読み 0 の確認は読み 2 が担う。t2 は読み 0 の終わり
        let confirmedAcrossFailure = judge(observation(reads: 3, failing: [1], trees: [tree(at: 0, [element("OK")])]))
        XCTAssertEqual(confirmedAcrossFailure.readyMs, 1200 + 4 - 1000)
        // 確認できる読みが失敗だけなら揃わない
        let noConfirmation = judge(observation(reads: 2, failing: [1], trees: [tree(at: 0, [element("OK")])]))
        XCTAssertEqual(noConfirmation.readyMissing, "notReadyBeforeNextAction")
    }

    func testReadsBeforeTheLastInjectionAreIgnored() {
        // 読み 0..2 は最後の注入(1100)より前 → 木が揃っていても数えない
        let result = judge(observation(reads: 6, startingAt: 1070, trees: [tree(at: 0, [element("OK")])]))
        // 1070, 1080, 1090 は除外。1100 の読み(index 3)から数える
        XCTAssertEqual(result.readyMs, 1100 + 4 - 1000)
    }

    func testTreesCarryOverAcrossUnchangedReads() {
        let result = judge(observation(reads: 6, trees: [
            tree(at: 0, [element("other")]),
            tree(at: 2, [element("OK")]),
        ]))
        // 読み 2 で揃い、木の記録が無い読み 3 は読み 2 の木が続く → t2 は読み 2
        XCTAssertEqual(result.readyMs, 1220 + 4 - 1000)
    }

    func testEndReasonsWithoutAHit() {
        let never = [tree(at: 0, [element("other")])]
        XCTAssertEqual(judge(observation(reads: 4, trees: never, endReason: "cap")).readyMissing, "observationTimeout")
        XCTAssertEqual(judge(observation(reads: 4, trees: never, endReason: "nextInjection")).readyMissing,
                       "notReadyBeforeNextAction")
        XCTAssertEqual(judge(observation(reads: 4, trees: never, truncated: true)).readyMissing,
                       "observationTruncated")
        // 理由を言えない終わり方は readyMissing を省く(丸めない)。注入の事実は載る
        let stopped = judge(observation(reads: 4, trees: never, endReason: "stopped"))
        XCTAssertNil(stopped.readyMissing)
        XCTAssertNil(stopped.readyMs)
        XCTAssertEqual(stopped.injections, 2)
    }

    func testHitWinsOverCapAndTruncation() {
        let result = judge(observation(reads: 4, trees: [tree(at: 0, [element("OK")])],
                                       endReason: "cap", truncated: true))
        XCTAssertEqual(result.readyMs, 1204 - 1000)
        XCTAssertNil(result.readyMissing)
    }

    func testObservationNotFoundIsLost() {
        let result = judge(ResponseObservation(found: false))
        XCTAssertEqual(result.readyMissing, "observationLost")
        XCTAssertEqual(result.injections, 2)
    }

    func testMissingCarriesInjectionFacts() {
        let result = ResponseReadyJudge.missing(.noTarget, facts: facts)
        XCTAssertEqual(result, ResponseReadyUpdate(injectionSpanMs: 100, injections: 2, readyMissing: "noTarget"))
    }

    func testApplyingUpdateFillsTheRecord() {
        let base = ResponseMeasurementRecord(busyBeforeAction: false, quietWaitMs: 1, firstFrameMs: 40,
                                             firstFrameMissing: nil)
        let applied = base.applying(ResponseReadyUpdate(readyMs: 300, readyAfterLastInjectionMs: 200,
                                                        injectionSpanMs: 100, injections: 2,
                                                        readyDecidedBy: "tree", readyIdentity: "locator"))
        XCTAssertEqual(applied.firstFrameMs, 40)
        XCTAssertEqual(applied.readyMs, 300)
        XCTAssertEqual(applied.readyIdentity, "locator")
        XCTAssertNil(applied.readyMissing)
    }
}
