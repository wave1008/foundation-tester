// emptyTreeNote(要素が1つも無い木であること自体を言う。2026-08-13 の監査)。
//
// 実測した形: Android Chrome の初回起動ダイアログを `ft_tap … snapshotAfter: true` で閉じた直後、
// 応答は `screen: 1080x2424` の1行だけだった。**空の一覧と「何も無い画面」は別**なのに、
// 遷移中であるという手掛かりが応答のどこにも無く、読み手は木を信じて次の手を撃てる。
//
// この形はコーパスに置けない(NoteCoverageTests.knownSilent の当該コメント)ので、
// 両方向をここで固定する。

import XCTest
@testable import fleetest_mcp
import FTCore

final class EmptyTreeNoteTests: XCTestCase {

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1080, height: 2424),
                         elements: elements, truncatedCount: 0)
    }

    func testFiresOnAnEmptyTree() {
        let note = MCPServer.emptyTreeNote(snapshot([]))
        XCTAssertTrue(note.contains("the element list is empty"), note)
        XCTAssertTrue(note.contains("waitFor"), "次の一手まで書くこと: \(note)")
    }

    /// 陰性: 要素が1つでもあれば黙る(「ほぼ空」では出さない —— 何件から空と呼ぶかを
    /// 決められないうえ、少ない木は打ち切り・interactiveOnly でも普通に起きる)
    func testStaysSilentWithASingleElement() {
        let only = ElementInfo(ref: 1, type: "other", identifier: "navigationBarBackground",
                               label: nil, value: nil, placeholder: nil, enabled: true,
                               frame: FTRect(x: 0, y: 2361, width: 1080, height: 63), depth: 3)
        XCTAssertEqual(MCPServer.emptyTreeNote(snapshot([only])), "")
    }

    /// 目録に載っていること(応答の組み立て側へ直に書かない規律)と、**scrollTo にも載る**こと
    /// —— ft_scroll_to が空の木を返す形は ft_snapshot と同じだけ起きる
    func testIsInTheCatalogForBothContexts() {
        let entry = NoteCatalog.snapshotNotes.first { $0.key == "emptyTreeNote" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.contexts, [.snapshot, .scrollTo])
    }
}
