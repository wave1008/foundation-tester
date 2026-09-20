// MCP の数値引数(Int/Double)は `MCPServer.intArgument`/`doubleArgument`(MCPServer.swift)を
// 唯一の取り出し口とする。直読み(`args["…"] as? Int`/`as? Double`/`as? [Any]`)は別型を黙って
// nil に潰し、呼び手はそれを「値が無い」と区別できない —— ft_tap {"ref": "8"} が黙って ref を
// 諦めて x/y フォールバックへ落ちた実害(2026-09-20 の負荷テスト)がその型。
//
// 新しい直読みを見た目で見逃さないようソースを走査して固定する。

import Foundation
import XCTest

final class NumericArgumentSourceScanTests: XCTestCase {

    /// `<相対パス>#<行の中身(前後空白を除く)>` の形で、意図して直読みのままにしている箇所。
    /// **行番号ではなく中身で見る** —— 同じファイルの無関係な編集で行がずれても壊れない。
    /// scrollFrame は Int(ref)/String(selector) のどちらも正当な値で、非 Int は「別の正当な形」
    /// であって「型が違う」ではない(resolveScrollFrameArg のコメント参照。型の拒否は
    /// 入口の validateScrollFrameArg が別途行う)
    private static let exempt: Set<String> = [
        #"Sources/fleetest-mcp/MCPServer+Snapshot.swift#if let ref = args["scrollFrame"] as? Int {"#,
    ]

    private static let pattern = try! NSRegularExpression(
        // `\b` は `]` の後では成立しない(両側とも非単語文字)ので、配列形は単語境界を要求しない
        pattern: #"args\["[^"]+"\]\s*as\?\s*((Int|Double)\b|\[Any\])"#)

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
                // 行コメントより右側は見ない(この呼び出し形を説明する doc コメントは実際の
                // 呼び出しではない)
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

    /// 走査そのものが動いていることの確認(既知の直読みを検出できること)。
    /// 全滅させて素通しする形を塞ぐ(緩めすぎた正規表現・パス解決の誤りなど)
    func testScanFindsEveryKnownExemptedReadDirectly() {
        let found = Set(Self.hits.map { "\($0.file)#\($0.text)" })
        for entry in Self.exempt {
            XCTAssertTrue(found.contains(entry),
                          "走査が既知の直読みを見つけられていない(パス解決か正規表現が壊れている): \(entry)")
        }
    }

    func testNumericArgumentsAreReadOnlyThroughTheSharedHelper() {
        let offenders = Self.hits.filter { !Self.exempt.contains("\($0.file)#\($0.text)") }
        XCTAssertTrue(offenders.isEmpty, """
            MCP の数値引数は MCPServer.intArgument(_:_:)/doubleArgument(_:_:) を通す —— \
            直読み(as? Int/as? Double)は文字列などの別型を渡されたときに黙って nil になり、\
            呼び手は型の誤りに気づけない。
            \(offenders.map { "\($0.file):\($0.line) \($0.text)" }.joined(separator: "\n"))
            """)
    }
}
