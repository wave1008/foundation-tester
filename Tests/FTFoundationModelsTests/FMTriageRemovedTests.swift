// FM の失敗トリアージ(分類・要約・修正案)は 2026-09-15 に撤去した(ユーザー決定。docs/maintainer-notes.md §21)。
// 照合相手の無い自由文で、実レポート 30 件のうち要約 13 件・分類の約 3 割が事実を誤った。
// 戻すなら、同じ手順で誤りの率を測ってから(§21 の「測り方」)。

import XCTest

final class FMTriageRemovedTests: XCTestCase {

    /// Sources のどこにも FM トリアージの型・呼び出し口・フラグが無いこと
    func testNoFMTriageRemainsInSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var hits: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in ["TriageSuggestion", "TriageInfo", "func triage(goal", "\"no-triage\"", "triageEnabled"]
            where text.contains(needle) {
                hits.append("\(url.lastPathComponent): \(needle)")
            }
        }
        XCTAssertGreaterThan(scanned, 100, "走査が Sources に届いていない")
        XCTAssertEqual(hits, [], "FM の失敗トリアージが戻っている(§21 の測り方で誤りの率を測ってから)")
    }
}
