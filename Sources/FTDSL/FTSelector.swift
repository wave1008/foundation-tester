// セレクタ式のパース。文字列 1 本を `||` で分割し、各節を FlowLocator に写像する。
//   #login_btn                       → id
//   ログイン                          → label(完全一致→部分一致は StepExecutor.match の挙動)
//   .Button / .Button[2]             → type(+順番)
//   .Switch#PHOTOS_UPLOAD_...        → type + id
//   .Switch=Resource Upload ...      → type + label
//   #list >> .Cell[2]                → スコープ(祖先 >> 子孫。[n] はスコープ内で数える)
//   .Button:near(送信)               → 近接アンカー(候補のうちアンカーに最も近いもの)
// [n] は 1 オリジン(.TextField[1] = 1番目の TextField。内部の FlowLocator.index は 0 オリジン)。
// パースは失敗しない(解釈できない節は label として扱う)。
// `||` と `>>` の分割は括弧の外だけ(`:near(...)` の中は割らない)。`>>` は `||` より強く結合する
// (`#a >> .Cell || #b` = (#a >> .Cell) か #b)。ラベルに `>>`/`:near(` を含めたいときは `=` エスケープ。

import Foundation
import FTCore

public struct FTSelector {
    /// 元のセレクタ式(ログ・レポート・修正提案用)
    public let text: String
    public let primary: FlowLocator
    public let fallbacks: [FlowLocator]

    public static func parse(_ text: String) -> FTSelector {
        let clauses = splitTopLevel(text, separator: "||")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let locators = clauses.map(parseClause)
        guard let first = locators.first else {
            return FTSelector(text: text, primary: FlowLocator(label: text), fallbacks: [])
        }
        return FTSelector(text: text, primary: first, fallbacks: Array(locators.dropFirst()))
    }

    /// 生ラベル(# や . で始まるテキスト)をそのまま label として使う場合
    public static func label(_ text: String) -> FTSelector {
        FTSelector(text: text, primary: FlowLocator(label: text), fallbacks: [])
    }

    static func parseClause(_ clause: String) -> FlowLocator {
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        // `=` エスケープは最優先(生ラベルに `>>` や `:near(` を含められる唯一の手段)
        if trimmed.hasPrefix("=") { return FlowLocator(label: String(trimmed.dropFirst())) }
        let segments = splitTopLevel(trimmed, separator: ">>")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard segments.count > 1, let last = segments.last else { return parseSegment(trimmed) }
        var target = parseSegment(last)
        target.scope = segments.dropLast().map(parseSegment)
        return target
    }

    /// `>>` で割った 1 区間。`:near(...)` を剥がして残りを単純節としてパースする
    static func parseSegment(_ segment: String) -> FlowLocator {
        if segment.hasPrefix("=") { return FlowLocator(label: String(segment.dropFirst())) }
        if segment.hasSuffix(")"), let marker = segment.range(of: ":near(") {
            let base = String(segment[segment.startIndex..<marker.lowerBound])
            let anchor = String(segment[marker.upperBound..<segment.index(before: segment.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            // 土台かアンカーが空の `:near()` は式として無意味 → 解釈せず生ラベル扱い(パースは失敗しない契約)
            if !base.isEmpty, !anchor.isEmpty {
                var locator = parseSimple(base.trimmingCharacters(in: .whitespaces))
                // アンカー側にも `||` のフォールバック連鎖を書ける(先に解決できたものを使う)
                locator.near = splitTopLevel(anchor, separator: "||")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map(parseSegment)
                return locator
            }
        }
        return parseSimple(segment)
    }

    static func parseSimple(_ clause: String) -> FlowLocator {
        if clause.hasPrefix("=") {
            // 生ラベルのエスケープ(# や . で始まるラベルを label として扱う)
            return FlowLocator(label: String(clause.dropFirst()))
        }
        if clause.hasPrefix("#") {
            return FlowLocator(id: String(clause.dropFirst()))
        }
        if clause.hasPrefix("."), clause.count > 1 {
            let body = clause.dropFirst()
            if let hashIndex = body.firstIndex(of: "#") {
                let type = String(body[body.startIndex..<hashIndex])
                let id = String(body[body.index(after: hashIndex)...])
                return FlowLocator(id: id, type: type.isEmpty ? nil : type)
            }
            if let eqIndex = body.firstIndex(of: "=") {
                let type = String(body[body.startIndex..<eqIndex])
                let label = String(body[body.index(after: eqIndex)...])
                return FlowLocator(label: label, type: type.isEmpty ? nil : type)
            }
            if body.hasSuffix("]"), let bracketIndex = body.firstIndex(of: "[") {
                let type = String(body[body.startIndex..<bracketIndex])
                let indexText = String(body[body.index(after: bracketIndex)..<body.index(before: body.endIndex)])
                if let ordinal = Int(indexText) {
                    // 表記 1 オリジン → 内部 0 オリジン
                    return FlowLocator(type: type, index: max(0, ordinal - 1))
                }
            }
            return FlowLocator(type: String(body))
        }
        return FlowLocator(label: clause)
    }

    /// 区切り文字で分割する。ただし括弧の外だけ(`:near(a||b)` を割らない)
    static func splitTopLevel(_ text: String, separator: String) -> [String] {
        guard let first = separator.first else { return [text] }
        var parts: [String] = []
        var current = ""
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "(" {
                depth += 1
            } else if char == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, char == first, text[index...].hasPrefix(separator) {
                parts.append(current)
                current = ""
                index = text.index(index, offsetBy: separator.count)
                continue
            }
            current.append(char)
            index = text.index(after: index)
        }
        parts.append(current)
        return parts
    }

    /// FlowLocator をセレクタ式の 1 節に戻す(修正提案・コード生成用)。
    /// scope / near も含めて往復する(parse(serialize(x)) == x)
    public static func serialize(_ locator: FlowLocator) -> String {
        var text = serializeSimple(locator)
        guard !text.isEmpty else { return "" }
        let anchorTexts = (locator.near ?? []).map(serialize).filter { !$0.isEmpty }
        if !anchorTexts.isEmpty {
            text += ":near(\(anchorTexts.joined(separator: "||")))"
        }
        let scopeTexts = (locator.scope ?? []).map(serialize).filter { !$0.isEmpty }
        if !scopeTexts.isEmpty {
            text = scopeTexts.joined(separator: " >> ") + " >> " + text
        }
        return text
    }

    private static func serializeSimple(_ locator: FlowLocator) -> String {
        if let id = locator.id {
            if let type = locator.type { return ".\(type)#\(id)" }
            return "#\(id)"
        }
        if let label = locator.label {
            // 既知の非対応: 型併記(.Type=ラベル)は `=` エスケープと併用できないため、
            // `>>` や `:near(` を含むラベルを型付きで表現することはできない(実 UI では起きない)
            if let type = locator.type { return ".\(type)=\(label)" }
            // # や . で始まるラベル、構文記号を含むラベルは = でエスケープして id/type/スコープ節と区別する
            if label.hasPrefix("#") || label.hasPrefix(".") || label.hasPrefix("=")
                || label.contains(">>") || label.contains(":near(") {
                return "=\(label)"
            }
            return label
        }
        if let type = locator.type {
            // 内部 index(0 オリジン)→ 表記(1 オリジン)。1番目は [1] を省略して .Type とする
            if let index = locator.index, index > 0 { return ".\(type)[\(index + 1)]" }
            return ".\(type)"
        }
        return ""
    }

    /// ロケータ連鎖をセレクタ式に戻す
    public static func serialize(primary: FlowLocator, fallbacks: [FlowLocator]) -> String {
        ([primary] + fallbacks).map(serialize).filter { !$0.isEmpty }.joined(separator: "||")
    }
}
