// StepCommandText.swift
// ステップ表の「コマンド」列の表示表現(実行時 description。例: tap "ラベル")と
// シナリオソースのコマンド呼び出しコードの相互変換。GUI のセル内インライン編集が使う。
// 方針: 動詞と文字列引数の構成が変わらない編集(セレクタ・入力値・期待値の変更)は
// ソース行の文字列リテラルだけを置換し、表示に現れない引数(timeout: / duration: 等)を
// 完全保存する。動詞や構成が変わったときだけ呼び出し全体を生成し直す
// (procedure のようにブロック { を伴う行の種類変更は不可)。

import Foundation

public enum StepCommandTextError: Error, LocalizedError, Equatable {
    case unrecognized
    case blockCommand
    case sourceNotRewritable(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognized:
            return "コマンドを解釈できません。コマンド列と同じ形式で入力してください"
                + "(例: tap \"ラベル\" / type \"欄\" \"文字\" / exist \"#id||ラベル\")"
        case .blockCommand:
            return "この行はブロック({ })を伴うため、コマンドの種類は変更できません"
        case .sourceNotRewritable(let verb):
            return "この行(\(verb))は表からは書き換えられません(ソースを直接編集してください)"
        }
    }
}

public enum StepCommandText {

    /// 表示表現を解釈した結果(verb は表示側の動詞。launch のバンドルは strings に入る)
    public struct Parsed: Equatable {
        public let verb: String
        /// クォート付き引数(セレクタ・入力値・期待値。launch/relaunch のバンドルも含む)
        public let strings: [String]
        /// 末尾の「 (optional)」(tap / type / press / scrollTo のみ受け付ける)
        public let optionalFlag: Bool
        /// 非クォートの単語引数(swipe の方向 / wait の秒数)
        public let word: String?
    }

    /// コマンド列の表示表現を解釈する。編集対象にできない表現(ifCanSelect・scene 系・
    /// 未知コマンド)は nil(セル編集の可否判定にも使う)
    public static func parse(_ display: String) -> Parsed? {
        var text = display.trimmingCharacters(in: .whitespaces)
        var optionalFlag = false
        if text.hasSuffix(" (optional)") {
            optionalFlag = true
            text = String(text.dropLast(" (optional)".count))
                .trimmingCharacters(in: .whitespaces)
        }

        if text == "terminate" {
            return optionalFlag ? nil
                : Parsed(verb: "terminate", strings: [], optionalFlag: false, word: nil)
        }
        guard let spaceIndex = text.firstIndex(of: " ") else {
            // launch / relaunch はバンドル省略も受け付ける(クラス既定のアプリを起動)
            if !optionalFlag, text == "launch" || text == "relaunch" {
                return Parsed(verb: text, strings: [], optionalFlag: false, word: nil)
            }
            return nil
        }
        let verb = String(text[..<spaceIndex])
        let rest = String(text[text.index(after: spaceIndex)...])
            .trimmingCharacters(in: .whitespaces)

        switch verb {
        case "tap", "press", "scrollTo":
            guard let selector = unquote(rest) else { return nil }
            return Parsed(verb: verb, strings: [selector], optionalFlag: optionalFlag, word: nil)
        case "exist", "screenIs", "procedure":
            guard !optionalFlag, let value = unquote(rest) else { return nil }
            return Parsed(verb: verb, strings: [value], optionalFlag: false, word: nil)
        case "type":
            guard let (selector, input) = unquotePair(rest, separator: "\" \"") else { return nil }
            return Parsed(verb: verb, strings: [selector, input],
                          optionalFlag: optionalFlag, word: nil)
        case "textIs", "valueIs":
            guard !optionalFlag,
                  let (selector, expected) = unquotePair(rest, separator: "\" == \"") else {
                return nil
            }
            return Parsed(verb: verb, strings: [selector, expected],
                          optionalFlag: false, word: nil)
        case "swipe":
            guard !optionalFlag, ["up", "down", "left", "right"].contains(rest) else {
                return nil
            }
            return Parsed(verb: verb, strings: [], optionalFlag: false, word: rest)
        case "wait":
            let number = rest.hasSuffix("s") ? String(rest.dropLast()) : rest
            guard !optionalFlag, let seconds = Double(number), seconds >= 0 else { return nil }
            return Parsed(verb: verb, strings: [], optionalFlag: false,
                          word: formatSeconds(seconds))
        case "launch", "relaunch":
            guard !optionalFlag, !rest.isEmpty, !rest.contains(" "), !rest.contains("\"") else {
                return nil
            }
            return Parsed(verb: verb, strings: [rest], optionalFlag: false, word: nil)
        default:
            return nil
        }
    }

    /// 表示表現の編集をソースのコード部分(ScenarioSourceEditor.commandCode の戻り値)へ
    /// 適用した新しいコードを返す。動詞・文字列引数の構成・optional が変わらなければ
    /// 文字列リテラルの置換のみ(その他の引数を保存)、変わったときは呼び出し全体を再生成
    public static func apply(display: String, toCode code: String) throws -> String {
        guard let parsed = parse(display) else {
            throw StepCommandTextError.unrecognized
        }
        guard let call = scanCall(code) else {
            throw StepCommandTextError.sourceNotRewritable(String(code.prefix(20)))
        }
        if call.verb == funcName(forVerb: parsed.verb),
           !parsed.strings.isEmpty,
           call.literalRanges.count == parsed.strings.count,
           optionalCompatible(parsed, call) {
            var result = code
            for (range, string) in zip(call.literalRanges, parsed.strings).reversed() {
                result.replaceSubrange(range, with: escaped(string))
            }
            return result
        }
        if call.hasTrailingBrace {
            throw StepCommandTextError.blockCommand
        }
        guard renewableFuncs.contains(call.verb) else {
            throw StepCommandTextError.sourceNotRewritable(call.verb)
        }
        return try render(parsed)
    }

    // MARK: - 内部

    /// リテラル置換だけで済むかの optional 判定。表示に optional が現れるのは tap のみ
    /// なので tap は厳密比較、他の動詞はサフィックス無し = 意思表示なし(ソースの
    /// optional: true を保存)、有り = ソースにも必要(無ければ再生成で付ける)
    private static func optionalCompatible(_ parsed: Parsed, _ call: Call) -> Bool {
        if parsed.verb == "tap" { return parsed.optionalFlag == call.hasOptionalTrue }
        return parsed.optionalFlag ? call.hasOptionalTrue : true
    }

    /// 表示の動詞 → ソースの関数名
    private static func funcName(forVerb verb: String) -> String {
        switch verb {
        case "launch": return "launchApp"
        case "relaunch": return "relaunchApp"
        case "terminate": return "terminateApp"
        default: return verb
        }
    }

    /// 呼び出し全体の生成し直しを許すソース関数(これ以外は生 Swift とみなして触らない。
    /// procedure はブロックを伴うため文字列リテラル置換のみ=ここに含めない)
    private static let renewableFuncs: Set<String> = [
        "tap", "type", "press", "swipe", "scrollTo", "exist", "textIs", "valueIs",
        "screenIs", "launchApp", "relaunchApp", "terminateApp", "wait",
    ]

    /// 解釈結果から正規形の呼び出しコードを生成する
    private static func render(_ parsed: Parsed) throws -> String {
        let optionalArg = parsed.optionalFlag ? ", optional: true" : ""
        switch parsed.verb {
        case "tap", "press", "scrollTo":
            return "\(parsed.verb)(\(literal(parsed.strings[0]))\(optionalArg))"
        case "exist", "screenIs":
            return "\(parsed.verb)(\(literal(parsed.strings[0])))"
        case "type", "textIs", "valueIs":
            return "\(parsed.verb)(\(literal(parsed.strings[0])), "
                + "\(literal(parsed.strings[1]))\(optionalArg))"
        case "swipe":
            return "swipe(.\(parsed.word ?? "up"))"
        case "wait":
            return "wait(\(parsed.word ?? "1"))"
        case "launch", "relaunch":
            let name = funcName(forVerb: parsed.verb)
            return parsed.strings.isEmpty
                ? "\(name)()" : "\(name)(\(literal(parsed.strings[0])))"
        case "terminate":
            return "terminateApp()"
        default:
            // procedure など: 構成が変わる編集は受け付けない(ブロック行を壊さない)
            throw StepCommandTextError.blockCommand
        }
    }

    /// コード部分の呼び出し構造(動詞・文字列リテラルの中身の範囲・ブロック { の有無)
    private struct Call {
        let verb: String
        let literalRanges: [Range<String.Index>]
        let hasTrailingBrace: Bool
        let hasOptionalTrue: Bool
    }

    private static func scanCall(_ code: String) -> Call? {
        guard let verbRange = code.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*"#, options: .regularExpression) else {
            return nil
        }
        var literals: [Range<String.Index>] = []
        var outside = ""  // 文字列リテラル外の文字("{"・"optional: true" の検出用)
        var inString = false
        var isEscaped = false
        var contentStart = code.startIndex
        var index = verbRange.upperBound
        while index < code.endIndex {
            let char = code[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    literals.append(contentStart..<index)
                    inString = false
                }
            } else if char == "\"" {
                inString = true
                contentStart = code.index(after: index)
            } else {
                outside.append(char)
            }
            index = code.index(after: index)
        }
        guard !inString else { return nil }  // 閉じていない文字列 = 解釈不能
        return Call(
            verb: String(code[verbRange]),
            literalRanges: literals,
            hasTrailingBrace: outside.contains("{"),
            hasOptionalTrue: outside.range(
                of: #"optional:\s*true"#, options: .regularExpression) != nil)
    }

    /// Swift 文字列リテラルの中身へのエスケープ(ScenarioCodeGen.literal と同方針)
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func literal(_ text: String) -> String {
        "\"\(escaped(text))\""
    }

    /// `"S"` → S(StepDescription.unquote と同じ規則)
    private static func unquote(_ text: String) -> String? {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return nil }
        return String(text.dropFirst().dropLast())
    }

    private static func unquotePair(_ text: String, separator: String) -> (String, String)? {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return nil }
        let inner = text.dropFirst().dropLast()
        guard let range = inner.range(of: separator) else { return nil }
        return (String(inner[..<range.lowerBound]), String(inner[range.upperBound...]))
    }

    /// 2.0 → "2"、0.5 → "0.5"(wait の生成用。StepDescription.formatSeconds と同じ)
    private static func formatSeconds(_ seconds: Double) -> String {
        if seconds == seconds.rounded(), abs(seconds) < 1e15 {
            return String(Int(seconds))
        }
        return String(seconds)
    }
}
