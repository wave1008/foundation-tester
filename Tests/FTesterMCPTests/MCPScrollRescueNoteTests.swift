// 実アプリ(Apple マップ)監査由来の ft_scroll_to 改善2件:
//   A. 半開きシート救済(自動展開+再試行)がレイアウトを変えたことを伝える
//      (MCPServer.sheetExpansionLayoutNote)。検出できるものは名指しする:
//      救済前に横ページャ(pageIndicator)があり救済後に消えていれば、`direction` がもう
//      ページ送りの意味を持たないことまで言う
//   B. ft_scroll_to の所要時間の内訳(MCPServer.scrollTimingNote)。短い探索ではうるさくしない

import XCTest
import FTCore
@testable import ftester_mcp

final class MCPScrollExpansionLayoutNoteTests: XCTestCase {

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app",
                         screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    private func pager(_ ref: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: "pageIndicator", identifier: nil, label: "1 of 5", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 150, y: 800, width: 100, height: 20), depth: 2)
    }

    private func row(_ ref: Int, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: "row_\(ref)", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: y, width: 402, height: 60), depth: 2)
    }

    /// **本丸**: 救済前にあった横ページャが救済後に消えていれば、縦リスト化を名指しする
    /// (実測: Apple マップの経路一覧が「横ページャ・全5ページ」→「縦リスト」に化けた回。
    /// 直前の ft_snapshot の「direction: right で届く」という案内と食い違っていた)
    func testPagerDisappearingMentionsTheVerticalListChange() {
        let before = snapshot([pager(), row(2, y: 820)])
        let after = snapshot([row(2, y: 100), row(3, y: 160)])
        let note = MCPServer.sheetExpansionLayoutNote(before: before, after: after)
        XCTAssertTrue(note.contains("pageIndicator"), note)
        XCTAssertTrue(note.contains("vertical list") || note.contains("single vertical"), note)
        XCTAssertTrue(note.contains("direction"), note)
    }

    /// 救済前後どちらにも pageIndicator が居るなら、縦リスト化の具体文は出さない
    /// (ページャはまだ生きているので「無くなった」は嘘になる)
    func testPagerPresentInBothDoesNotClaimItDisappeared() {
        let before = snapshot([pager()])
        let after = snapshot([pager()])
        let note = MCPServer.sheetExpansionLayoutNote(before: before, after: after)
        XCTAssertFalse(note.contains("pageIndicator"), note)
        XCTAssertTrue(note.contains("Expanding the sheet"), note)
    }

    /// 救済前後どちらにも pageIndicator が無いなら、汎用の一文だけ(それ以上の推測をしない)
    func testPagerAbsentInBothStaysGeneric() {
        let before = snapshot([row(1, y: 700)])
        let after = snapshot([row(1, y: 100)])
        let note = MCPServer.sheetExpansionLayoutNote(before: before, after: after)
        XCTAssertFalse(note.contains("pageIndicator"), note)
        XCTAssertTrue(note.contains("Expanding the sheet"), note)
    }

    /// 救済前に無く救済後に**現れた**(横ページャが新たに出た)場合も「消えた」とは言わない
    /// (hadPager が偽なので guard を通らず generic のまま)
    func testPagerAppearingIsNotReportedAsDisappearing() {
        let before = snapshot([row(1, y: 700)])
        let after = snapshot([pager()])
        let note = MCPServer.sheetExpansionLayoutNote(before: before, after: after)
        XCTAssertFalse(note.contains("pageIndicator"), note)
    }
}

final class MCPScrollTimingNoteTests: XCTestCase {

    /// 救済ありなら、閾値未満でも必ず内訳を出す(遅さの主因を切り分けたい回だから)
    func testTimingNoteWithRescueAlwaysShows() {
        let note = MCPServer.scrollTimingNote(totalMs: 15_600, swipes: 7, rescueMs: 9_100)
        XCTAssertTrue(note.contains("15.6s"), note)
        XCTAssertTrue(note.contains("7 swipe(s)"), note)
        XCTAssertTrue(note.contains("sheet-expand rescue"), note)
        XCTAssertTrue(note.contains("9.1s"), note)
    }

    /// 救済なし・閾値以上なら内訳だけ出す(rescue の言及は無い)
    func testTimingNoteWithoutRescueAboveThreshold() {
        let note = MCPServer.scrollTimingNote(totalMs: 2_700, swipes: 3, rescueMs: nil)
        XCTAssertTrue(note.contains("2.7s"), note)
        XCTAssertTrue(note.contains("3 swipe(s)"), note)
        XCTAssertFalse(note.contains("rescue"), note)
    }

    /// **短い探索でうるさくしない**: 閾値未満・救済なしは空文字列
    func testTimingNoteBelowThresholdWithoutRescueIsSilent() {
        XCTAssertEqual(MCPServer.scrollTimingNote(totalMs: 500, swipes: 1, rescueMs: nil), "")
    }

    /// 閾値ちょうどは「未満」ではないので出す(境界値)
    func testTimingNoteAtExactThresholdShows() {
        let note = MCPServer.scrollTimingNote(
            totalMs: MCPServer.scrollTimingNoteThresholdMs, swipes: 2, rescueMs: nil)
        XCTAssertFalse(note.isEmpty, note)
    }

    /// **救済単独でゲートを開ける**こと: totalMs が閾値未満でも rescueMs があれば出す。
    /// 上の2テストはどちらも totalMs 側だけで判定条件を満たしてしまうので、rescueMs の
    /// OR 条件が抜けても(totalMs だけを見るよう縮退しても)拾えない。ここで totalMs を
    /// 閾値未満に固定し、rescueMs だけがゲートを開けていることを直接確認する
    func testTimingNoteWithRescueShowsEvenBelowThreshold() {
        let note = MCPServer.scrollTimingNote(totalMs: 500, swipes: 2, rescueMs: 300)
        XCTAssertFalse(note.isEmpty, note)
        XCTAssertTrue(note.contains("sheet-expand rescue"), note)
    }

    /// swipes が nil でも壊れない(scrollSwipes は runScrollSearch を経由しない経路では nil)。
    /// 空の括弧にはしない
    func testTimingNoteHandlesNilSwipesWithoutCrashing() {
        let note = MCPServer.scrollTimingNote(totalMs: 5_000, swipes: nil, rescueMs: nil)
        XCTAssertTrue(note.contains("5.0s"), note)
        XCTAssertFalse(note.contains("()"), note)
        XCTAssertFalse(note.contains("swipe(s)"), note)
    }

    /// swipes が nil でも救済ありなら救済区間は出る(片方だけ欠けても壊れない)
    func testTimingNoteHandlesNilSwipesWithRescue() {
        let note = MCPServer.scrollTimingNote(totalMs: 9_000, swipes: nil, rescueMs: 4_000)
        XCTAssertTrue(note.contains("sheet-expand rescue"), note)
        XCTAssertTrue(note.contains("4.0s"), note)
        XCTAssertFalse(note.contains("swipe(s)"), note)
    }
}
