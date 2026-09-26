import Foundation
import XCTest

/// `RunRecordPack.trimmedForStorage`(Sources/FTCore/RunRecordPack.swift)は、api results の
/// パックへ入れる前に `ScenarioRunRecord.timeline` を「notes を持つステップだけ・
/// index/description/status/notes の4欄だけ」に縮小する。その前提は
/// 「`RunResultsQuery` が timeline から読むのは notes だけ」(実測: 記録のバイト数の84%が
/// timeline。docs/results-json.md §出力キャッシュ)。**この前提が崩れたら縮小そのものが誤りになる**
/// ので、RunResultsQuery.swift が `.timeline` へアクセスする行を機械的に見つけ、そこで読む
/// フィールドが `notes` だけであることを固定する。
final class TimelineNotesOnlyScanTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var targetFile: URL {
        repoRoot.appendingPathComponent("Sources/FTCore/RunResultsQuery.swift")
    }

    func testRunResultsQueryOnlyReadsNotesFromTimeline() throws {
        let source = try String(contentsOf: Self.targetFile, encoding: .utf8)
        let lines = source.components(separatedBy: "\n").filter { $0.contains(".timeline") }
        XCTAssertFalse(lines.isEmpty, "sanity: this scan must actually find RunResultsQuery's .timeline usage"
            + " (did the file move or get renamed?)")

        let fieldAccess = try NSRegularExpression(pattern: #"\$0\.(\w+)"#)
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in fieldAccess.matches(in: line, range: range) {
                let field = (line as NSString).substring(with: match.range(at: 1))
                XCTAssertEqual(field, "notes",
                    "RunResultsQuery reads TimelineStepRecord.\(field) (line: \(line.trimmingCharacters(in: .whitespaces))) —"
                    + " RunRecordPack.trimmedForStorage only keeps index/description/status/notes when packing,"
                    + " so widen the trim there too before relying on this field from a pack")
            }
        }
    }
}
