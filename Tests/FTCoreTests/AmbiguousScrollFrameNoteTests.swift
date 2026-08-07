// `scrollFrame:` が複数一致したときの申告。**添字なしの指定は matches[0] を黙って採る**ので、
// 同名の容器が並ぶ画面(Google マップ Android は1画面に `#recycler_view` が4つ)では
// 先頭の横カルーセルを掴んだまま「見つからない」で終わる。2026-08-07 に実測した形。

import XCTest
@testable import FTCore

final class AmbiguousScrollFrameNoteTests: XCTestCase {

    private func rows(_ count: Int, id: String) -> [ElementInfo] {
        (0..<count).map { i in
            ElementInfo(ref: i + 1, type: "collectionView", identifier: id, label: nil,
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(i * 200), width: 400, height: 120),
                        depth: 2, scrollable: true)
        }
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    func testAmbiguousSelectorIsReportedWithTheRectThatWasUsed() {
        let elements = rows(4, id: "recycler_view")
        var locator = FlowLocator(); locator.id = "recycler_view"
        let note = StepExecutor.ambiguousScrollFrameNote(locator, picked: elements[0],
                                                         in: snapshot(elements))
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("matched 4 elements") == true, note ?? "")
        XCTAssertTrue(note?.contains("(0,0 400x120)") == true, note ?? "")
        XCTAssertTrue(note?.contains("[n]") == true, note ?? "")
    }

    /// 添字を書いてあるなら選択済み = 黙る
    func testExplicitIndexSilencesTheNote() {
        let elements = rows(4, id: "recycler_view")
        var locator = FlowLocator(); locator.id = "recycler_view"; locator.index = 2
        XCTAssertNil(StepExecutor.ambiguousScrollFrameNote(locator, picked: elements[2],
                                                           in: snapshot(elements)))
    }

    /// 一意なら黙る
    func testUniqueSelectorSilencesTheNote() {
        let elements = rows(1, id: "search_list_layout")
        var locator = FlowLocator(); locator.id = "search_list_layout"
        XCTAssertNil(StepExecutor.ambiguousScrollFrameNote(locator, picked: elements[0],
                                                           in: snapshot(elements)))
    }
}
