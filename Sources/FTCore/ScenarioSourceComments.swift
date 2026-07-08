// ScenarioSourceComments.swift
// シナリオソース(Swift DSL)の行末コメント(// ...)抽出。
// GUI のステップ表の「説明」列が、dry-run の step イベント(file/line)から
// コマンド行のコメントを引くために使う。ソース文字列の走査だけを行い、
// ファイル I/O は呼び出し側が担う(ScenarioSourceEditor と同方針)。
// 文字列リテラル内の //(URL 等)は簡易クォート認識で無視する。
// 非対応: raw string(#"..."#)・複数行文字列(""")・ブロックコメント(/* */)。
// 生成コード(ScenarioCodeGen)と手書きシナリオの実態では通常文字列+// で十分

import Foundation

public enum ScenarioSourceComments {

    /// 1 行から行末コメントの本文を取り出す(前後空白除去。コメントが無い・空なら nil)
    public static func trailingComment(inLine line: String) -> String? {
        var inString = false
        var escaped = false
        var previousWasSlash = false
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
                previousWasSlash = false
            } else if char == "\"" {
                inString = true
                previousWasSlash = false
            } else if char == "/" {
                if previousWasSlash {
                    let body = line[line.index(after: index)...]
                        .trimmingCharacters(in: .whitespaces)
                    return body.isEmpty ? nil : body
                }
                previousWasSlash = true
            } else {
                previousWasSlash = false
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// ソース全体から指定した行番号(1 起点)の行末コメントをまとめて引く
    /// (1 シナリオ分をファイル 1 回の分割で処理するための便宜 API。
    ///  範囲外の行番号・コメントの無い行は結果に含めない)
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
