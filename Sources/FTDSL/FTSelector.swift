// セレクタ式のパース。文字列 1 本を `||` で分割し、各節を FlowLocator に写像する。
//   #login_btn                       → id
//   ログイン                          → label(完全一致→部分一致は StepExecutor.match の挙動)
//   .button / .button[2]             → type(+順番。**型名は先頭小文字**)
//   .switch#PHOTOS_UPLOAD_...        → type + id
//   .switch=Resource Upload ...      → type + label
//   #list >> .clickable[2]                → スコープ(祖先 >> 子孫。[n] はスコープ内で数える)
//   .switch:right(通知)              → 方向アンカー(アンカーの右にある候補だけ。左/上/下も同型)
// [n] は 1 オリジン(.textField[1] = 1番目の textField。内部の FlowLocator.index は 0 オリジン)。
// パースは失敗しない(解釈できない節は label として扱う)。**構文の誤り(未知のマーカー・綴り誤り・
// 先頭大文字の型名・不正な序数)は validationError が別経路で落とす**(パースだけだと
// `.button:rigth(x)` が黙ってラベル扱いになり、notExist 等が空振りで緑になるため。
// run 開始時と dry-run が呼ぶ)。
// `||` と `>>` の分割は括弧の外だけ(`:right(...)` の中は割らない)。`>>` は `||` より強く結合する
// (`#a >> .clickable || #b` = (#a >> .clickable) か #b)。ラベルに `>>`/`:方向(` を含めたいときは `=` エスケープ。

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

    /// 方向マーカーの唯一の表(パース・検証・シリアライズが共有する)
    static let directionMarkers: [(marker: String, direction: FlowDirection)] = [
        (":right(", .right), (":left(", .left), (":above(", .above), (":below(", .below),
    ]

    static func parseClause(_ clause: String) -> FlowLocator {
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        // `=` エスケープは最優先(生ラベルに `>>` や `:right(` を含められる唯一の手段)
        if trimmed.hasPrefix("=") { return FlowLocator(label: String(trimmed.dropFirst())) }
        let segments = splitTopLevel(trimmed, separator: ">>")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard segments.count > 1, let last = segments.last else { return parseSegment(trimmed) }
        var target = parseSegment(last)
        target.scope = segments.dropLast().map(parseSegment)
        return target
    }

    /// `>>` で割った 1 区間。方向マーカー(`:right(...)` 等)を剥がして残りを単純節としてパースする
    static func parseSegment(_ segment: String) -> FlowLocator {
        if segment.hasPrefix("=") { return FlowLocator(label: String(segment.dropFirst())) }
        if segment.hasSuffix(")"), let found = firstDirectionMarker(in: segment) {
            let base = String(segment[segment.startIndex..<found.range.lowerBound])
            let anchor = String(segment[found.range.upperBound..<segment.index(before: segment.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            // 土台かアンカーが空の `:right()` は式として無意味 → 解釈せず生ラベル扱い
            // (パースは失敗しない契約。誤りとしては validationError が捕まえる)
            if !base.isEmpty, !anchor.isEmpty {
                var locator = parseSimple(base.trimmingCharacters(in: .whitespaces))
                locator.direction = found.direction
                // アンカー側にも `||` のフォールバック連鎖を書ける(先に解決できたものを使う)
                locator.anchor = splitTopLevel(anchor, separator: "||")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map(parseSegment)
                return locator
            }
        }
        return parseSimple(segment)
    }

    /// 最も左に現れる方向マーカー(土台はマーカーより前にあるため、左端が正しい区切り)
    static func firstDirectionMarker(in segment: String)
        -> (range: Range<String.Index>, direction: FlowDirection)? {
        directionMarkers
            .compactMap { marker, direction in
                segment.range(of: marker).map { (range: $0, direction: direction) }
            }
            .min { $0.range.lowerBound < $1.range.lowerBound }
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

    /// 区切り文字で分割する。ただし括弧の外だけ(`:right(a||b)` を割らない)
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
    /// scope / 方向アンカーも含めて往復する(parse(serialize(x)) == x)
    public static func serialize(_ locator: FlowLocator) -> String {
        var text = serializeSimple(locator)
        guard !text.isEmpty else { return "" }
        let anchorTexts = (locator.anchor ?? []).map(serialize).filter { !$0.isEmpty }
        if let direction = locator.direction, !anchorTexts.isEmpty {
            text += ":\(direction.rawValue)(\(anchorTexts.joined(separator: "||")))"
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
            // `>>` や `:right(` を含むラベルを型付きで表現することはできない(実 UI では起きない)
            if let type = locator.type { return ".\(type)=\(label)" }
            // # や . で始まるラベル、構文記号を含むラベルは = でエスケープして id/type/スコープ節と区別する
            if label.hasPrefix("#") || label.hasPrefix(".") || label.hasPrefix("=")
                || label.contains(">>") || directionMarkers.contains(where: { label.contains($0.marker) }) {
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

    // MARK: - 構文検証

    /// セレクタ式の構文エラー(無ければ nil)。**パースと違い失敗する**のがこの関数の存在理由:
    /// パースは解釈できない節を label に落とすため、`:rigth(x)` のような綴り誤りが「そんなラベルは
    /// 無い」= notExist/countIs(x,0) では**必ず成功**になってしまう。実行前にここで落とす。
    /// 呼ぶのは run 開始時の一括検査と `api run --dry-run`(デバイス不要)。
    public static func validationError(_ text: String) -> String? {
        if let error = unbalancedParenError(text) { return error }
        for clause in splitTopLevel(text, separator: "||") {
            let trimmed = clause.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // `=` エスケープは全体が生ラベル = 構文解釈しない
            if trimmed.hasPrefix("=") { continue }
            for segment in splitTopLevel(trimmed, separator: ">>") {
                if let error = segmentError(segment.trimmingCharacters(in: .whitespaces)) {
                    return error
                }
            }
        }
        return nil
    }

    private static func unbalancedParenError(_ text: String) -> String? {
        var depth = 0
        for char in text {
            if char == "(" { depth += 1 }
            if char == ")" {
                depth -= 1
                if depth < 0 { return "括弧が閉じる側で余っています: \"\(text)\"" }
            }
        }
        return depth > 0 ? "括弧が閉じていません: \"\(text)\"" : nil
    }

    private static func segmentError(_ segment: String) -> String? {
        if segment.isEmpty || segment.hasPrefix("=") { return nil }
        // `:名前(` の形をした未知のマーカー(綴り誤り・Shirates 等の他ツール記法の混入)
        if let unknown = unknownMarker(in: segment) {
            let known = directionMarkers.map { $0.marker + "…)" }.joined(separator: " / ")
            return "未知のセレクタ構文 \"\(unknown)\" です: \"\(segment)\"。"
                + "使えるのは \(known)(ラベルに含めたいときは先頭に = を付けてエスケープ)"
        }
        if let found = firstDirectionMarker(in: segment) {
            guard segment.hasSuffix(")") else {
                return "方向セレクタの後ろに余分な文字があります: \"\(segment)\""
            }
            let base = String(segment[segment.startIndex..<found.range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let anchor = String(segment[found.range.upperBound..<segment.index(before: segment.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            if base.isEmpty { return "方向セレクタの土台がありません: \"\(segment)\"" }
            if anchor.isEmpty { return "方向セレクタのアンカーが空です: \"\(segment)\"" }
            // アンカー側も同じ規則で検証する(入れ子の綴り誤りを見逃さない)
            for part in splitTopLevel(anchor, separator: "||") {
                if let error = segmentError(part.trimmingCharacters(in: .whitespaces)) { return error }
            }
            return ordinalError(base) ?? typeCaseError(base)
        }
        return ordinalError(segment) ?? typeCaseError(segment)
    }

    /// 型名は先頭小文字(`.button`)。スナップショットが返す型名と同じ綴りに揃えてある
    /// (ElementInfo.normalizedType)。旧記法 `.Button` は決して一致しないので明示エラーにする
    private static func typeCaseError(_ segment: String) -> String? {
        guard segment.hasPrefix("."), segment.count > 1 else { return nil }
        let body = segment.dropFirst()
        guard let first = body.first, first.isUppercase else { return nil }
        let corrected = first.lowercased() + body.dropFirst()
        return "型名は先頭小文字で書きます: \"\(segment)\" → \".\(corrected)\""
    }

    /// `.Type[n]` の n が 1 以上の整数か。`[abc]` や `[0]` は型名の一部として黙って解釈され、
    /// 決して一致しないロケータになるためここで落とす
    private static func ordinalError(_ segment: String) -> String? {
        guard segment.hasPrefix("."), segment.hasSuffix("]"),
              let bracket = segment.firstIndex(of: "[") else { return nil }
        let inner = String(segment[segment.index(after: bracket)..<segment.index(before: segment.endIndex)])
        guard let ordinal = Int(inner) else {
            return "序数は整数で書きます(1 オリジン): \"\(segment)\""
        }
        return ordinal >= 1 ? nil : "序数は 1 以上です(1 オリジン): \"\(segment)\""
    }

    /// `:` + 英字 + `(` の並びのうち、既知の方向マーカーでないもの
    private static func unknownMarker(in segment: String) -> String? {
        var index = segment.startIndex
        while let colon = segment[index...].firstIndex(of: ":") {
            var cursor = segment.index(after: colon)
            while cursor < segment.endIndex, segment[cursor].isLetter {
                cursor = segment.index(after: cursor)
            }
            if cursor < segment.endIndex, segment[cursor] == "(", cursor > segment.index(after: colon) {
                let marker = String(segment[colon...cursor])
                if !directionMarkers.contains(where: { $0.marker == marker }) { return marker }
            }
            guard colon < segment.endIndex else { break }
            index = segment.index(after: colon)
        }
        return nil
    }
}
