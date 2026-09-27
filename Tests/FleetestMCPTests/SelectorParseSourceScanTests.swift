// MCP のセレクタ構文検査は `MCPServer.parseSelectorArgument(_:argument:)`(MCPServer.swift)を
// 唯一の入口とする。呼び手供給の文字列(selector/scrollFrame/waitFor/to)を素の
// `FTSelector.parse(...)` へ渡すと、DSL が実行前に落とす構文誤り(`FTSelector.validationError`。
// 例: `selector: "#"`)がそのまま通り、見つからないまま探索を最後まで振り切る
// (実測: ft_scroll_to の selector "#" が46秒スワイプし続けた)。
//
// 新しい素通しを見た目で見逃さないようソースを走査して固定する。

import Foundation
import XCTest

final class SelectorParseSourceScanTests: XCTestCase {

    /// `<相対パス>#<行の中身(前後空白を除く)>` の形で、意図してヘルパーを経由しない箇所。
    /// **行番号ではなく中身で見る**(同じファイルの無関係な編集で行がずれても壊れない)。
    /// 理由は各行に添える
    private static let exempt: Set<String> = [
        // ヘルパー自身の定義(唯一の呼び口。ここだけが素の parse を持つ)
        #"Sources/fleetest-mcp/MCPServer.swift#return FTSelector.parse(text)"#,
        // matchedElements: セレクタ解決の共有ユーティリティ。呼び手は scrollTo の selector
        // (ゲート後)と waitFor(ゲート後)のみで、いずれも呼ばれる前に
        // parseSelectorArgument を通っている
        #"Sources/fleetest-mcp/MCPServer+Snapshot.swift#let parsed = FTSelector.parse(selectorText)"#,
        // scrollAreaHint: ft_scroll_to 内でのみ呼ばれ、同じ args["scrollFrame"] は
        // validateScrollFrameArg が既にゲート済み
        #"Sources/fleetest-mcp/MCPServer+Hints.swift#let locator = FTSelector.parse(frame).primary"#,
        // similarLabelsHint / notationHint: どちらも同じ行を持つ(同一パターン)。
        // 呼び手は selector(scrollTo。ゲート後)と waitFor(ゲート後)のみ
        #"Sources/fleetest-mcp/MCPServer+Hints.swift#let locator = FTSelector.parse(selectorText).primary"#,
        // recordInteraction: `selector` は SelectorNaming(graded) が木から合成した文字列で、
        // 呼び手供給ではない(構文は常に正当)
        #"Sources/fleetest-mcp/MCPServer+Draft.swift#if let selector { step.locator = FTSelector.parse(selector).primary }"#,
    ]

    private static let pattern = try! NSRegularExpression(pattern: #"\bFTSelector\.parse\("#)

    private struct Hit {
        let file: String
        let line: Int
        let text: String
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
    }

    private static func scan() -> [Hit] {
        let root = repoRoot
        let sourcesRoot = root.appendingPathComponent("Sources/fleetest-mcp")
        guard let walker = FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var found: [Hit] = []
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            guard url.pathExtension == "swift" else { continue }
            let relative = "Sources/fleetest-mcp" + url.path.dropFirst(sourcesRoot.path.count)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, substring) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(substring)
                // 行コメントより右側は見ない(呼び出し形を説明する doc コメントは実際の呼び出しではない)
                let codePart = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
                let nsCode = codePart as NSString
                let matches = Self.pattern.matches(in: codePart, range: NSRange(location: 0, length: nsCode.length))
                guard !matches.isEmpty else { continue }
                found.append(Hit(file: relative, line: index + 1, text: line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return found
    }

    private static let hits: [Hit] = scan()

    /// 走査そのものが動いていることの確認(既知の許容箇所を検出できること)。
    /// 全滅させて素通しする形を塞ぐ(緩めすぎた正規表現・パス解決の誤りなど)
    func testScanFindsEveryKnownExemptedCall() {
        let found = Set(Self.hits.map { "\($0.file)#\($0.text)" })
        for entry in Self.exempt {
            XCTAssertTrue(found.contains(entry),
                          "走査が既知の許容箇所を見つけられていない(パス解決か正規表現が壊れている): \(entry)")
        }
    }

    /// 走査が実際にファイルへ当たっていることの確認(0件は「壊れて何も見ていない」と
    /// 区別できない)
    func testScanActuallyScannedFiles() {
        XCTAssertGreaterThan(Self.hits.count, 0, "走査が1件もヒットしていない — パス解決が壊れている")
    }

    func testSelectorParseIsOnlyCalledThroughTheSharedGate() {
        let offenders = Self.hits.filter { !Self.exempt.contains("\($0.file)#\($0.text)") }
        XCTAssertTrue(offenders.isEmpty, """
            呼び手供給のセレクタ文字列(selector/scrollFrame/waitFor/to)は \
            MCPServer.parseSelectorArgument(_:argument:) を通す —— 素の FTSelector.parse(...) は \
            構文誤り(例: "#")を無検査で通し、見つからないまま探索が最後まで振り切る。
            \(offenders.map { "\($0.file):\($0.line) \($0.text)" }.joined(separator: "\n"))
            """)
    }
}
