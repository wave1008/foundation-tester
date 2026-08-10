// ft_batch のステップ文法: 「DSL の呼び出し1行」だけを解釈する限定パーサ。
//
//   line   := name [ "(" args ")" ]
//   args   := arg ("," arg)*
//   arg    := [ label ":" ] value
//   value  := string | number | bool | "." ident
//
// Swift 全体は解釈しない —— 入れ子呼び出し・配列・演算子・クロージャは構文的に受け付けず、
// 明確なエラーにする(価は BatchLineParserTests)。
//
// **BatchLineParser / BatchArgSpecTable は純粋関数**: デバイスにも MCPServer の状態にも依存しない
// (Foundation のみ import)。テストしやすくするための設計で、意図して FTDSL へ触れていない。
// シグネチャ文字列を DSLCommandIndex から引く責務は呼び出し側(MCPServer.planBatchStep)に残す。
//
// BatchStepResolver だけは例外(FTDSL を import)—— パース結果を、既存の `batchStepBuilders`
// クロージャがそのまま食える `[String: Any]` へ変換するには、DSLCommandIndex のシグネチャ文字列
// (位置引数の名前・ラベルの妥当性)が要るため。

import Foundation
import FTDSL

// MARK: - パース結果の型

enum BatchLineValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    /// `.down` のようなドット付き識別子。値としては裸の文字列("down")として扱う
    case dotIdent(String)
}

struct BatchLineArg: Equatable {
    let label: String?
    let value: BatchLineValue
}

struct BatchParsedLine: Equatable {
    let name: String
    let args: [BatchLineArg]
}

/// 構文レベルの拒否。`commandName` は名前だけ読めた時点(その後で構文が壊れていても)入る ——
/// このファイルは FTDSL に触れないので、シグネチャを添えたメッセージは呼び出し側が組み立てる
struct BatchLineSyntaxError: Error, Equatable {
    let rawLine: String
    let commandName: String?
    let reason: String

    /// シグネチャ・`ft_dsl_commands` への案内を含まない土台部分。呼び出し側
    /// (`MCPServer.planBatchStep`)が `commandName` を使って肉付けする
    var baseMessage: String {
        "could not parse \"\(rawLine)\" — \(reason). Each step is one DSL call, e.g. tap(\"#id\")."
    }
}

// MARK: - 行パーサ

enum BatchLineParser {

    /// 前後の空白と行末の `;` を落とす(改行分割は呼び出し側 `MCPServer` の役目 —— このパーサは
    /// 1行だけを見る)
    static func normalize(_ rawLine: String) -> String {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasSuffix(";") {
            line = String(line.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line
    }

    static func parse(_ rawLine: String) throws -> BatchParsedLine {
        let line = normalize(rawLine)
        let chars = Array(line)
        var i = 0

        func fail(_ reason: String, name: String? = nil) -> BatchLineSyntaxError {
            BatchLineSyntaxError(rawLine: rawLine, commandName: name, reason: reason)
        }
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        func skipSpaces() { while let c = peek(), c == " " || c == "\t" { i += 1 } }

        skipSpaces()
        let nameStart = i
        while let c = peek(), c.isLetter || c.isNumber || c == "_" { i += 1 }
        guard i > nameStart else { throw fail("expected a command name") }
        let name = String(chars[nameStart..<i])
        skipSpaces()

        var args: [BatchLineArg] = []
        if peek() == "(" {
            i += 1
            skipSpaces()
            if peek() == ")" {
                i += 1
            } else {
                while true {
                    let arg = try parseArg(chars, &i, rawLine: rawLine, name: name)
                    args.append(arg)
                    skipSpaces()
                    guard let c = peek() else { throw fail("missing closing \")\"", name: name) }
                    if c == "," { i += 1; skipSpaces(); continue }
                    if c == ")" { i += 1; break }
                    throw fail("expected \",\" or \")\"", name: name)
                }
            }
            skipSpaces()
        }
        guard i == chars.count else {
            throw fail("unexpected text after the call: \"\(String(chars[i...]))\"", name: name)
        }
        return BatchParsedLine(name: name, args: args)
    }

    private static func parseArg(_ chars: [Character], _ i: inout Int, rawLine: String,
                                 name: String) throws -> BatchLineArg {
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        func skipSpaces() { while let c = peek(), c == " " || c == "\t" { i += 1 } }
        func fail(_ reason: String) -> BatchLineSyntaxError {
            BatchLineSyntaxError(rawLine: rawLine, commandName: name, reason: reason)
        }

        skipSpaces()
        // ラベルは「識別子の直後に ':'」の形だけ受ける。true/false は識別子と衝突するので、
        // ':' が続かなければブール値として扱う
        if let c = peek(), c.isLetter || c == "_" {
            let wordStart = i
            var j = i
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                j += 1
            }
            let word = String(chars[wordStart..<j])
            var k = j
            while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
            if k < chars.count, chars[k] == ":" {
                i = k + 1
                skipSpaces()
                let value = try parseValue(chars, &i, rawLine: rawLine, name: name)
                return BatchLineArg(label: word, value: value)
            }
            if word == "true" { i = j; return BatchLineArg(label: nil, value: .bool(true)) }
            if word == "false" { i = j; return BatchLineArg(label: nil, value: .bool(false)) }
            throw fail(Self.notAValueReason)
        }
        let value = try parseValue(chars, &i, rawLine: rawLine, name: name)
        return BatchLineArg(label: nil, value: value)
    }

    private static let notAValueReason = "arguments must be a quoted string, a number, "
        + "true/false, or .identifier — nested calls, arrays, and operators are not supported"

    private static func parseValue(_ chars: [Character], _ i: inout Int, rawLine: String,
                                   name: String) throws -> BatchLineValue {
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        func fail(_ reason: String) -> BatchLineSyntaxError {
            BatchLineSyntaxError(rawLine: rawLine, commandName: name, reason: reason)
        }
        guard let c = peek() else { throw fail("expected a value") }

        if c == "\"" {
            i += 1
            var s = ""
            while true {
                guard i < chars.count else { throw fail("unterminated string") }
                let ch = chars[i]
                if ch == "\"" { i += 1; break }
                if ch == "\\" {
                    i += 1
                    guard i < chars.count else { throw fail("unterminated string") }
                    s.append(chars[i])  // \" と \\ を解く。それ以外はバックスラッシュを落として通す
                    i += 1
                    continue
                }
                s.append(ch)
                i += 1
            }
            return .string(s)
        }
        if c == "." {
            i += 1
            let start = i
            while let c2 = peek(), c2.isLetter || c2.isNumber || c2 == "_" { i += 1 }
            guard i > start else { throw fail("expected an identifier after \".\"") }
            return .dotIdent(String(chars[start..<i]))
        }
        if c == "-" || c.isNumber {
            let start = i
            if c == "-" { i += 1 }
            var sawDigit = false
            while let c2 = peek(), c2.isNumber { i += 1; sawDigit = true }
            if peek() == "." {
                i += 1
                while let c2 = peek(), c2.isNumber { i += 1; sawDigit = true }
            }
            if let c2 = peek(), c2 == "e" || c2 == "E" {
                i += 1
                if let sign = peek(), sign == "+" || sign == "-" { i += 1 }
                while let c2 = peek(), c2.isNumber { i += 1 }
            }
            let text = String(chars[start..<i])
            guard sawDigit, let n = Double(text) else {
                throw fail("could not parse \"\(text)\" as a number")
            }
            return .number(n)
        }
        if c.isLetter || c == "_" {
            let start = i
            while let c2 = peek(), c2.isLetter || c2.isNumber || c2 == "_" { i += 1 }
            let word = String(chars[start..<i])
            if word == "true" { return .bool(true) }
            if word == "false" { return .bool(false) }
        }
        throw fail(Self.notAValueReason)
    }
}

// MARK: - シグネチャ文字列 → 引数の形

/// 1つの呼び出し形の引数名(位置引数 / ラベル引数)。順序を保つ(メッセージの表示順に使う)
struct BatchArgForm: Equatable {
    let positional: [String]
    let labels: [String]
}

/// `DSLCommandIndex.signature` の文字列から引数名を導出する。**名前の一覧をハードコードしない** ——
/// 例外は `positionalOverrides`(シグネチャが引数リストの形をしていないコマンドだけ)と
/// `dictKeyAliases`(バッチの辞書キー語彙が DSL 自身のパラメータ名と食い違う箇所だけ)。
/// どちらも1件ずつしか無い(coverage テストが将来の増加を検出する)
enum BatchArgSpecTable {

    /// `swipe(.up / .down / .left / .right)` は1引数がまるごと enum の選択肢で、
    /// 通常の識別子リストとして解釈できない
    static let positionalOverrides: [String: [String]] = ["swipe": ["direction"]]

    /// バッチの辞書キー語彙は要素ロケータを常に "selector" と呼ぶが、
    /// `swipeElementToElement(from, to, durationSeconds:)` の DSL 自身は始点を "from" と呼ぶ。
    /// 受け取るビルダのキー名は変えない(CLAUDE.md)ので、ここで表示名だけ吸収する
    static let dictKeyAliases: [String: String] = ["from": "selector"]

    /// シグネチャ文字列(例: `"type(selector, text) / type(text)"`)を、呼び出し形ごとの
    /// 引数名リストへ分解する。解釈できない形(swipe 等)は override に無ければ結果から落ちる
    /// —— coverage テストが「ビルダを持つのに1つも形が取れないコマンド」を検出する
    static func forms(for command: String, signature: String) -> [BatchArgForm] {
        if let positional = positionalOverrides[command] {
            return [BatchArgForm(positional: positional, labels: [])]
        }
        return splitTopLevel(signature, separator: " / ").compactMap(parseForm)
    }

    private static func parseForm(_ form: String) -> BatchArgForm? {
        let trimmed = form.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "(") else {
            return BatchArgForm(positional: [], labels: [])
        }
        guard let close = matchingParen(trimmed, open: open) else { return nil }
        let afterClose = trimmed[trimmed.index(after: close)...]
            .trimmingCharacters(in: .whitespaces)
        guard afterClose.isEmpty else { return nil }
        let inner = trimmed[trimmed.index(after: open)..<close]
            .trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return BatchArgForm(positional: [], labels: []) }

        var positional: [String] = []
        var labels: [String] = []
        for rawToken in splitTopLevel(inner, separator: ",") {
            let token = rawToken.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { return nil }
            if token.hasSuffix(":") {
                let name = String(token.dropLast())
                guard isIdentifier(name) else { return nil }
                labels.append(name)
            } else {
                var name = token
                if name.hasSuffix("?") { name.removeLast() }
                guard isIdentifier(name) else { return nil }
                positional.append(name)
            }
        }
        return BatchArgForm(positional: positional, labels: labels)
    }

    /// 深さを見ながら区切る(括弧の中の区切り文字では割らない)。" / "(複数呼び出し形の区切り)と
    /// ","(引数の区切り)の両方に使う
    private static func splitTopLevel(_ s: String, separator: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "(" { depth += 1; current.append(s[i]); i = s.index(after: i); continue }
            if s[i] == ")" { depth -= 1; current.append(s[i]); i = s.index(after: i); continue }
            if depth == 0, s[i...].hasPrefix(separator) {
                parts.append(current)
                current = ""
                i = s.index(i, offsetBy: separator.count)
                continue
            }
            current.append(s[i])
            i = s.index(after: i)
        }
        parts.append(current)
        return parts
    }

    private static func matchingParen(_ s: String, open: String.Index) -> String.Index? {
        var depth = 0
        var i = open
        while i < s.endIndex {
            if s[i] == "(" { depth += 1 } else if s[i] == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first == "_" else { return false }
        return s.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

// MARK: - パース結果 → ビルダが食える [String: Any]

/// `BatchParsedLine.args` を、既存の `batchStepBuilders` クロージャがそのまま読める辞書へ変換する。
/// `declaredKeys` は「そのビルダが実際に読むキー」(`MCPServer.BatchStepBuilder.keys`。手で宣言、
/// signature から自動導出しない — signature には無いのに読むキーもある: 例 `type` の `timeout`)。
/// **未対応ラベルは黙って捨てず、signature に載っているかどうかでメッセージを変える**
enum BatchStepResolver {
    struct ResolveError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func resolve(command: String, signature: String, args: [BatchLineArg],
                        declaredKeys: [String]) throws -> [String: Any] {
        let forms = BatchArgSpecTable.forms(for: command, signature: signature)
        let positionalArgs = args.filter { $0.label == nil }
        let labeledArgs = args.filter { $0.label != nil }
        var raw: [String: Any] = [:]

        if !positionalArgs.isEmpty {
            guard let form = forms.first(where: { $0.positional.count == positionalArgs.count })
            else {
                throw ResolveError(message: "\(command) does not take \(positionalArgs.count)"
                    + " positional argument(s) — signature: \(signature). See ft_dsl_commands.")
            }
            for (index, name) in form.positional.enumerated() {
                let dictKey = BatchArgSpecTable.dictKeyAliases[name] ?? name
                try assign(&raw, dictKey: dictKey, value: positionalArgs[index].value,
                          command: command, displayName: name)
            }
        }

        // シグネチャ中のどの呼び出し形にも載っている名前の全体(位置・ラベル問わず) ——
        // 拒否したラベルを「対応していない」/「そもそも存在しない」に振り分けるためだけに使う
        let universe = Set(forms.flatMap { $0.positional + $0.labels })
        for arg in labeledArgs {
            let label = arg.label!
            let dictKey = BatchArgSpecTable.dictKeyAliases[label] ?? label
            guard declaredKeys.contains(dictKey) else {
                if universe.contains(label) {
                    throw ResolveError(message: "\(command) does not support \"\(label):\" in"
                        + " ft_batch — supported here: \(declaredKeys.joined(separator: ", "))."
                        + " Write the full form in the scenario instead.")
                }
                // **ref だけは理由まで返す**: 「そんな引数は無い」で終えると、渡し方を探して
                // もう1往復する。ref は DSL に存在しない概念なので、代わりに何を書くかまで言う
                if label == "ref" {
                    throw ResolveError(message: "ft_batch steps take a selector, not a ref — a ref"
                        + " is only valid against the snapshot it came from, and each step can"
                        + " change the tree, so a later step's ref would silently hit a different"
                        + " element. Write \(command)(\"#id\") (or a label / .type) instead;"
                        + " ft_snapshot prints the id next to each ref.")
                }
                throw ResolveError(message: "\(command) has no \"\(label):\" parameter —"
                    + " signature: \(signature). See ft_dsl_commands.")
            }
            guard raw[dictKey] == nil else {
                throw ResolveError(message: "\(command) got \"\(label):\" more than once.")
            }
            try assign(&raw, dictKey: dictKey, value: arg.value, command: command,
                      displayName: label)
        }
        return raw
    }

    // このバッチ辞書語彙で使われている全キーの型。3集合はどれとも重ならない
    // (現状 Bool 型のキーは無い —— containerInference/requireVisible/scroll は未対応のため)
    private static let stringKeys: Set<String> = ["selector", "text", "direction", "to", "scrollFrame"]
    private static let intKeys: Set<String> = ["maxSwipes", "repeat"]
    private static let doubleKeys: Set<String> = [
        "holdSeconds", "timeout", "scale", "durationSeconds", "dxRatio", "dyRatio",
    ]

    private static func assign(_ raw: inout [String: Any], dictKey: String, value: BatchLineValue,
                               command: String, displayName: String) throws {
        switch value {
        case .string(let s), .dotIdent(let s):
            guard stringKeys.contains(dictKey) else {
                throw ResolveError(message: mismatch(command, displayName, "\"\(s)\""))
            }
            raw[dictKey] = s
        case .number(let n):
            if intKeys.contains(dictKey) {
                raw[dictKey] = Int(n)
            } else if doubleKeys.contains(dictKey) {
                raw[dictKey] = n
            } else {
                throw ResolveError(message: mismatch(command, displayName, "\(n)"))
            }
        case .bool(let b):
            throw ResolveError(message: mismatch(command, displayName, "\(b)"))
        }
    }

    private static func mismatch(_ command: String, _ displayName: String, _ got: String) -> String {
        "\(command)'s \"\(displayName)\" does not accept \(got)."
    }
}
