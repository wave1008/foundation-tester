// ScenarioSourceComments.swift
// シナリオソース(Swift DSL)の行末コメント(// ...)抽出。dry-run の step イベント(file/line)から
// ステップ一覧の「説明」列を埋めるのに使う。ソース文字列の走査のみ行い、ファイル I/O は呼び出し側の責務。
// 文字列リテラル内の //(URL 等)は簡易クォート認識で無視する。
// 非対応: raw string(#"..."#)・複数行文字列(""")・ブロックコメント(/* */)
// (生成コード・手書きシナリオの実態では通常文字列+// で十分なため)

import Foundation

public enum ScenarioSourceComments {

    /// 1 行から行末コメントの本文を取り出す(前後空白除去。コメントが無い・空なら nil)
    public static func trailingComment(inLine line: String) -> String? {
        guard let start = trailingCommentStart(inLine: line) else { return nil }
        let body = line[line.index(start, offsetBy: 2)...]
            .trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    /// 行末コメントの「//」の開始位置(文字列リテラル内の // は無視)。無ければ nil。
    /// ScenarioSourceEditor.setTrailingComment が位置を必要とするため公開
    public static func trailingCommentStart(inLine line: String) -> String.Index? {
        var inString = false
        var escaped = false
        var previousSlashIndex: String.Index?
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                previousSlashIndex = nil
            } else if char == "\"" {
                inString = true
                previousSlashIndex = nil
            } else if char == "/" {
                if let first = previousSlashIndex { return first }
                previousSlashIndex = index
            } else {
                previousSlashIndex = nil
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// ソース全体から指定した行番号(1 起点)の行末コメントをまとめて引く
    /// (範囲外の行番号・コメントの無い行は結果に含めない)
    public static func trailingComments(inSource source: String,
                                        lines: Set<Int>) -> [Int: String] {
        guard let maxLine = lines.max() else { return [:] }
        var comments: [Int: String] = [:]
        var lineNumber = 0
        source.enumerateLines { line, stop in
            lineNumber += 1
            if lines.contains(lineNumber), let comment = trailingComment(inLine: line) {
                comments[lineNumber] = comment
            }
            if lineNumber >= maxLine { stop = true }
        }
        return comments
    }
}
