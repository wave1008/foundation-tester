// ソース走査テストが読む「MCP サーバの実装テキスト」。
// **宣言がどのファイルに居るかは契約ではない**(2,000行を超えたら分割する。CLAUDE.md
// 「ソース分割の方針」)ので、単一ファイルを名指しで開くと分割のたびに走査テストが落ちる。
// 名前順に連結した1本のテキストを配り、テスト側は関数名から範囲を切り出す。

import Foundation

enum MCPServerSourceText {

    /// `Sources/fleetest-mcp/MCPServer*.swift` を名前順に連結したもの。
    /// 切り出しの終端に「次の宣言のコメント」を使うテストがあるため、**ファイル境界では
    /// 改行2つで繋ぐ**(連結によって隣接しなかった宣言がくっつかないようにする)。
    static func combined() throws -> String {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("MCPServer") && $0.hasSuffix(".swift") }
            .sorted()
        return try names
            .map { try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n\n")
    }
}
