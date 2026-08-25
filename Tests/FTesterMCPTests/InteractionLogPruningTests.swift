// 下書きの刈り込み。
//
// 記録は「やったこと」であって「意図」ではない。行き止まりのタップも試し打ちも成功した操作なので
// 自動では本筋と見分けられない —— だから**番号を見せて選ばせる**。
// その番号と実際に落ちる手がズレたら機能ごと嘘になるので、対応をここで固定する。

import XCTest
import FTCore
@testable import ftester_mcp

final class InteractionLogPruningTests: XCTestCase {

    private func entries(_ names: [String]) -> [InteractionLog.Entry] {
        names.map { InteractionLog.Entry(step: FlowStep(action: $0), unresolved: nil,
                                         summary: $0) }
    }

    func testDropUsesOneBasedNumbersOfTheListing() {
        let result = InteractionLog.prune(entries(["a", "b", "c", "d"]), lastN: nil, drop: [2, 4])
        XCTAssertEqual(result.kept.map(\.summary), ["a", "c"])
        XCTAssertEqual(result.dropped, 2)
        XCTAssertTrue(result.ignored.isEmpty)
    }

    /// **番号は lastN で絞った後の並びに振る** —— 一覧を見て選ぶ道具なので、
    /// 見えている番号と落ちる手が一致していなければ意味がない
    func testDropIsAppliedAfterLastN() {
        let result = InteractionLog.prune(entries(["a", "b", "c", "d"]), lastN: 2, drop: [1])
        XCTAssertEqual(result.kept.map(\.summary), ["d"])
    }

    func testLastNLargerThanTheLogKeepsEverything() {
        let result = InteractionLog.prune(entries(["a", "b"]), lastN: 99, drop: [])
        XCTAssertEqual(result.kept.map(\.summary), ["a", "b"])
    }

    /// 範囲外は**黙って捨てない**。番号を1つ外しただけで別の手が落ちるので、
    /// 効かなかった指定に気付けないと誤った下書きを持ち帰る
    func testOutOfRangeNumbersAreReportedNotSilentlyIgnored() {
        let result = InteractionLog.prune(entries(["a", "b"]), lastN: nil, drop: [0, 3, 2])
        XCTAssertEqual(result.kept.map(\.summary), ["a"])
        XCTAssertEqual(result.ignored, [0, 3])
    }

    func testDuplicateNumbersDropOnceAndDoNotMiscount() {
        let result = InteractionLog.prune(entries(["a", "b", "c"]), lastN: nil, drop: [2, 2])
        XCTAssertEqual(result.kept.map(\.summary), ["a", "c"])
        XCTAssertEqual(result.dropped, 1)
    }

    /// 何も指定しなければ**素通し**(刈り込みが常時発火していないこと = 逆方向の変異)
    func testNoArgumentsKeepEverything() {
        let result = InteractionLog.prune(entries(["a", "b", "c"]), lastN: nil, drop: [])
        XCTAssertEqual(result.kept.map(\.summary), ["a", "b", "c"])
        XCTAssertEqual(result.dropped, 0)
    }

    // MARK: - 一覧と番号の対応

    func testListingNumbersMatchWhatDropWillRemove() {
        let scope = entries(["launch com.example", "tap \"#a\"", "tap \"#b\""])
        let listing = MCPServer.pruningListing(scope)
        XCTAssertTrue(listing.contains("1. launch com.example"), listing)
        XCTAssertTrue(listing.contains("2. tap \"#a\""), listing)
        XCTAssertTrue(listing.contains("3. tap \"#b\""), listing)
        // 一覧の 2 番を落とすと、消えるのは一覧に 2 番と書いてあった手
        let pruned = InteractionLog.prune(scope, lastN: nil, drop: [2])
        XCTAssertFalse(pruned.kept.contains { $0.summary == "tap \"#a\"" })
        XCTAssertEqual(pruned.kept.map(\.summary), ["launch com.example", "tap \"#b\""])
    }

    func testListingTellsHowToPrune() {
        let listing = MCPServer.pruningListing(entries(["a"]))
        XCTAssertTrue(listing.contains("drop:"), listing)
        XCTAssertTrue(listing.contains("lastN:"), listing)
    }
}
