// `open(…O_CREAT…)` には `O_NOFOLLOW` を付ける。台帳・ロックの置き場はサンドボックスの子も書けることが多く、
// 子が symlink を置くと親が先に空ファイルを作る・切り詰める・排他を崩される(2026-10-07 の棚卸し)。
// 最後の要素が symlink なら open は ELOOP で失敗する = 呼び手は「取れなかった」側へ倒れる

import XCTest

final class NoFollowOpenScanTests: XCTestCase {

    func testEveryCreatingOpenRefusesToFollowASymlink() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var creating = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains("O_CREAT") {
                creating += 1
                if !line.contains("O_NOFOLLOW") { offenders.append("\(url.lastPathComponent):\(index + 1)") }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan did not reach Sources")
        XCTAssertGreaterThan(creating, 10, "the scan found no creating open — the pattern no longer matches")
        XCTAssertEqual(offenders, [], "add O_NOFOLLOW (a symlink planted by a sandboxed scenario would be followed)")
    }
}
