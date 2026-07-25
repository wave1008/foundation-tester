// SelectorLint.swift
// シナリオ(.swift)の "#id" セレクタと SUT 契約書(ui-contract.md)のドリフト検査。
// 対象は #id のみ(ラベルはローカライズで揺れるため対象外)。CLI 側は
// Sources/ftester/ProjectCommands.swift の LintSelectors(`ftester project lint-selectors`)。

import Foundation

public enum SelectorLint {

    /// Swift ソースから "#id" 形式のセレクタリテラルを (id, 行番号[1始まり]) で抽出する。
    /// 各行はまず先頭の "//" 以降を単純な文字列検索で除去してからマッチさせる(ブロックコメント
    /// /* */ は対象外・文字列リテラル中の "//" も切り落とされ得るが DSL の実際の書き方では実害なし)。
    /// 既知の取りこぼし: 文字列補間("\(prefix)#id")・複合セレクタの一部("#a >> #b" はクォート
    /// 全体が #id と一致しないため拾えない)。DSL は tap("#id") のように単独クォート文字列で
    /// 渡すのが通常のため、これらは意図的に非対応。
    public static func selectorsInSwiftSource(_ source: String) -> [(id: String, line: Int)] {
        guard let regex = try? NSRegularExpression(pattern: "\"#([A-Za-z0-9_]+)\"") else {
            return []
        }
        var results: [(id: String, line: Int)] = []
        for (index, rawLine) in source.components(separatedBy: "\n").enumerated() {
            let line: String
            if let commentRange = rawLine.range(of: "//") {
                line = String(rawLine[rawLine.startIndex..<commentRange.lowerBound])
            } else {
                line = rawLine
            }
            let nsRange = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: nsRange) {
                guard let idRange = Range(match.range(at: 1), in: line) else { continue }
                results.append((id: String(line[idRange]), line: index + 1))
            }
        }
        return results
    }

    /// 契約 Markdown 全文から "#id" トークンを抽出する(バッククォート内外・"内外は問わない)。
    /// 見出し "# 見出し" は # 直後が空白のため通常マッチしない
    public static func idsInContract(_ markdown: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: "#[A-Za-z0-9_]+") else {
            return []
        }
        let nsRange = NSRange(markdown.startIndex..., in: markdown)
        var ids: Set<String> = []
        for match in regex.matches(in: markdown, range: nsRange) {
            guard let range = Range(match.range, in: markdown) else { continue }
            ids.insert(String(markdown[range].dropFirst()))
        }
        return ids
    }

    /// usedIDs(シナリオ側)と contractIDs(契約書側)の差分。
    /// unknown = 契約に無いのに使われている id(壊れる/壊れているおそれ)。
    /// unusedContractIDs = 契約にあるがどのシナリオからも参照されていない id(情報表示のみ)
    public static func drift(usedIDs: Set<String>, contractIDs: Set<String>)
        -> (unknown: Set<String>, unusedContractIDs: Set<String>) {
        (unknown: usedIDs.subtracting(contractIDs),
         unusedContractIDs: contractIDs.subtracting(usedIDs))
    }
}
