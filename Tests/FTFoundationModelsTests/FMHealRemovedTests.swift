// FM によるロケータ自己修復(FM ヒール)とヒールキャッシュは 2026-09-15 に撤去した(ユーザー決定。
// docs/maintainer-notes.md §22)。採用門(自己申告 confidence == "high")が実測で1度も開かず(0/272・
// E2E の witness は全 run で却下)、confidence は正誤と相関しなかった。修復はロケータの指紋照合だけが担う。
// 戻すなら、§21 と同じ手順で誤りの率を測ってから。

import XCTest

final class FMHealRemovedTests: XCTestCase {

    /// Sources のどこにも FM ヒールの型・呼び出し口・ヒールキャッシュが無いこと
    func testNoFMHealRemainsInSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var hits: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in ["func healLocator", "HealAttempt", "HealProposal", "LocatorRepairSuggestion",
                           "heal-cache.json", "class HealCache", "kind: \"heal\""]
            where text.contains(needle) {
                hits.append("\(url.lastPathComponent): \(needle)")
            }
        }
        XCTAssertGreaterThan(scanned, 100, "走査が Sources に届いていない")
        XCTAssertEqual(hits, [], "FM ヒールかヒールキャッシュが戻っている(§21 の測り方で誤りの率を測ってから)")
    }
}
