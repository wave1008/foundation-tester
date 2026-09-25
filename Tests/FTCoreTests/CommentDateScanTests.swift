// コメントに日付(`20xx-xx-xx`)を書かない(CLAUDE.md §コメント規約「設計経緯・履歴(日付)は書かない」)。
// 日付は編集判断に使われず、読むたびにトークンを払う。規約だけで止めずにいたら約1,000件溜まった。
// 事実は日付なしで残す: `(2026-07-25 実測)` → `(実測)`、`ユーザー決定 2026-09-15` → `ユーザー決定`。
//
// 走査するのはコメント部分だけ(`//` 以降・`/* */`・`<!-- -->`)。文字列リテラル中の日付(データ・書式)は対象外。
// 判定は行単位の近似: `//` の手前にある `"` が奇数ならその `//` は文字列内(URL 等)として読み飛ばす。
//
// **走査の対象外**: Tests/(フィクスチャに日付が要る)・TestProjects/(ユーザー資産)・docs/(台帳は日付が本体)・
// Sources の Generated/(protoc の生成物)

import Foundation
import XCTest

final class CommentDateScanTests: XCTestCase {

    /// 日付が契約・名前の一部であるもの。**理由の無い行を足さない**(足したくなったら日付を消す)。
    /// 各行が今も当たることを `testAllowlistEntriesStillMatch` が確かめる(表が腐って素通しの口になるのを防ぐ)
    private static let allowlist: [(file: String, date: String, reason: String)] = [
        ("Sources/FTCore/ResultsOutputCache.swift", "2026-06-01", "日付指定の書式の例"),
        ("Sources/fleetest-mcp/MCPServer.swift", "2025-06-18", "MCP プロトコルの版の名前"),
        ("Sources/fleetest-mcp/MCPServer.swift", "2025-03-26", "MCP プロトコルの版の名前"),
        ("Sources/fleetest-mcp/NoteCatalog.swift", "2026-08-16", "Bench/measurements.md の節の名前"),
        ("Sources/fleetest/RemoteRunDispatcher.swift", "2026-09-06", "ファイル名 bug-audit-2026-09-06.md の一部"),
    ]

    private static let roots: [(dir: String, extensions: Set<String>)] = [
        ("Sources", ["swift", "m", "h"]),
        ("vscode-fleetest/src", ["ts", "js", "mjs", "css"]),
    ]

    private static let skippedDirectories: Set<String> = ["Generated", "node_modules", ".build"]

    private static let datePattern = try! NSRegularExpression(pattern: "20[0-9]{2}-[0-9]{2}-[0-9]{2}")

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private struct Hit {
        let file: String
        let line: Int
        let date: String
        let text: String
    }

    private struct ScanResult {
        var filesScanned = 0
        var hits: [Hit] = []
    }

    /// プロセスに1回だけ走査する
    private static let result: ScanResult = scan()

    private static func scan() -> ScanResult {
        var out = ScanResult()
        let rootPath = repoRoot.path
        for (dir, extensions) in roots {
            guard let walker = FileManager.default.enumerator(
                at: repoRoot.appendingPathComponent(dir), includingPropertiesForKeys: [.isDirectoryKey])
            else { continue }
            for case let url as URL in walker {
                if skippedDirectories.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                guard extensions.contains(url.pathExtension),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                out.filesScanned += 1
                let relative = String(url.path.dropFirst(rootPath.count + 1))
                for (lineNo, comment) in commentSegments(text) {
                    let ns = comment as NSString
                    for m in datePattern.matches(in: comment, range: NSRange(location: 0, length: ns.length)) {
                        out.hits.append(Hit(file: relative, line: lineNo, date: ns.substring(with: m.range),
                                            text: comment.trimmingCharacters(in: .whitespaces)))
                    }
                }
            }
        }
        return out
    }

    /// 各行のコメント部分(行番号は 1 始まり)。ブロックコメント(`/* */`・`<!-- -->`)は行を跨いで追う
    static func commentSegments(_ text: String) -> [(Int, String)] {
        var segments: [(Int, String)] = []
        var blockEnd: String?
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = Substring(rawLine)
            var collected = ""
            while !line.isEmpty {
                if let end = blockEnd {
                    if let r = line.range(of: end) {
                        collected += line[..<r.lowerBound]
                        line = line[r.upperBound...]
                        blockEnd = nil
                    } else {
                        collected += line
                        line = ""
                    }
                    continue
                }
                let starts: [(String, String?)] = [("//", nil), ("/*", "*/"), ("<!--", "-->")]
                let next = starts.compactMap { open, close -> (Range<Substring.Index>, String?)? in
                    var search = line.startIndex..<line.endIndex
                    while let r = line.range(of: open, range: search) {
                        // 手前の `"` が奇数 = 文字列の中(URL・正規表現の断片)
                        if line[..<r.lowerBound].filter({ $0 == "\"" }).count % 2 == 0 { return (r, close) }
                        search = r.upperBound..<line.endIndex
                    }
                    return nil
                }.min { $0.0.lowerBound < $1.0.lowerBound }
                guard let (range, close) = next else { break }
                if let close {
                    blockEnd = close
                    line = line[range.upperBound...]
                } else {
                    collected += line[range.upperBound...]
                    line = ""
                }
            }
            if !collected.isEmpty { segments.append((index + 1, collected)) }
        }
        return segments
    }

    private static func isAllowed(_ hit: Hit) -> Bool {
        allowlist.contains { $0.file == hit.file && $0.date == hit.date }
    }

    func testNoDatesInComments() {
        let violations = Self.result.hits.filter { !Self.isAllowed($0) }
        XCTAssertTrue(violations.isEmpty, """
            コメントに日付を書かない(CLAUDE.md §コメント規約)。事実は残して日付だけ消す:
            `(2026-07-25 実測)` → `(実測)` / `ユーザー決定 2026-09-15` → `ユーザー決定`。
            日付が契約・名前の一部なら allowlist に理由付きで足す。
            \(violations.map { "\($0.file):\($0.line) \($0.text)" }.joined(separator: "\n"))
            """)
    }

    func testAllowlistEntriesStillMatch() {
        for entry in Self.allowlist {
            XCTAssertTrue(Self.result.hits.contains { $0.file == entry.file && $0.date == entry.date },
                          "allowlist の \(entry.file) / \(entry.date) はもう当たらない —— 行を消す")
        }
    }

    /// 走査がソースに届いていること(ルートの改名で空集合を走査して緑、を防ぐ)
    func testScanReachesSources() {
        XCTAssertGreaterThan(Self.result.filesScanned, 500)
    }

    func testCommentSegmentsExtraction() {
        let source = """
        let url = "https://example.com/2026-01-01" // 2026-02-02 実測
        /* 2026-03-03
           2026-04-04 */ let x = "2026-05-05"
        <!-- 2026-06-06 -->
        """
        let dates = Self.commentSegments(source).flatMap { _, comment -> [String] in
            let ns = comment as NSString
            return Self.datePattern.matches(in: comment, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }
        }
        XCTAssertEqual(dates, ["2026-02-02", "2026-03-03", "2026-04-04", "2026-06-06"])
    }
}
