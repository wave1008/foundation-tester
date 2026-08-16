// MCP の応答へ載せる文章の整形。
//
// FTCore のエラー文は CLI(`ftester …`)の利用者に向けて書かれていて、指示するのは
// `--project` のような**コマンドラインフラグ**。MCP のツールは同じ値を `project:` という
// **引数**で受けるので、そのまま素通しすると読み手は存在しないフラグを渡そうとする。
// 実測(2026-08-09・ft_list_devices): 「multiple projects exist. Pick one with --project」。
//
// **`ftester` から始まる例示コマンドの中は書き換えない** —— そこは本当にシェルへ打つ
// 文字列で、`ftester api list-scenarios project: X` は動かない。同じ1文に両方
// (`--project` の案内と候補一覧)が同居するので、行ごとではなく**直前の句**で判定する。

import Foundation

enum MCPMessageText {

    /// MCP のツール引数として実在する名前だけを書き換える(CLI にしかないフラグは触らない)。
    /// 長い名前を先に見る = `--project-dir` を `--project` として拾わないための順序ではなく、
    /// 境界チェック(`isFlagBoundary`)が本体。順序は最左一致を安定させるためだけ
    static let argumentFlags = ["scenario", "platform", "profile", "project", "serial", "port"]

    static func forMCP(_ message: String) -> String {
        message.split(separator: "\n", omittingEmptySubsequences: false)
            .map { rewriteLine(String($0)) }
            .joined(separator: "\n")
    }

    /// 1行ぶんの書き換え。**新しい文字列を組み立てる**(String の添字は変更で無効化されるため、
    /// replaceSubrange を回しながら添字を使い回さない)
    static func rewriteLine(_ line: String) -> String {
        var out = ""
        var rest = Substring(line)
        while let hit = firstFlag(in: rest) {
            out += rest[rest.startIndex..<hit.range.lowerBound]
            // 直前の句に `ftester` が居れば、それはシェルへ打つコマンド行
            out += isInsideCommand(out) ? String(rest[hit.range]) : "\(hit.flag):"
            rest = rest[hit.range.upperBound...]
        }
        return out + rest
    }

    /// 最も左に現れる `--<flag>`。後ろに識別子文字が続くもの(`--project-dir`)は取らない
    private static func firstFlag(in text: Substring) -> (range: Range<String.Index>, flag: String)? {
        var best: (range: Range<String.Index>, flag: String)?
        for flag in argumentFlags {
            var searchFrom = text.startIndex
            while let found = text.range(of: "--\(flag)", range: searchFrom..<text.endIndex) {
                guard isFlagBoundary(text, after: found.upperBound) else {
                    searchFrom = found.upperBound
                    continue
                }
                if best == nil || found.lowerBound < best!.range.lowerBound {
                    best = (found, flag)
                }
                break
            }
        }
        return best
    }

    /// フラグ名の終わりが本当に終わりか(`--project-dir` / `--projects` を弾く)
    private static func isFlagBoundary(_ text: Substring, after index: String.Index) -> Bool {
        guard index < text.endIndex else { return true }
        let next = text[index]
        return !(next.isLetter || next.isNumber || next == "-" || next == "_")
    }

    /// 直前の句(前の `.` / `;` / 行頭から現在位置まで)に `ftester` が居るか。
    /// 実例: 「… exist. Pick one with --project」→ 句は "Pick one with " = 居ない(書き換える) /
    /// 「ftester api list-scenarios --project」→ 句に居る(そのまま)
    static func isInsideCommand(_ preceding: String) -> Bool {
        let boundary = preceding.lastIndex { $0 == "." || $0 == ";" }
        let clause = boundary.map { String(preceding[preceding.index(after: $0)...]) } ?? preceding
        return clause.contains("ftester")
    }
}
