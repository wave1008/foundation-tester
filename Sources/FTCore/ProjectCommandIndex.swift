// ProjectCommandIndex.swift
// scenarios/ 配下にユーザーが書いた `@FTCommand("summary")` 付き関数を走査し、DSL 索引
// (`fleetest api dsl-commands` / MCP `ft_dsl_commands`)へ載せる。マーカーの実体は
// `FTDSL.FTCommand`(展開が空の peer マクロ。Sources/FTDSL/Macros.swift)—— ここはソーステキストを
// 直接読む純粋な走査で、コンパイル済み成果物にもデバイスにも触らない。
//
// **意図した簡略化**(シナリオのヘルパー関数の実態に合わせた線引き。フルの Swift パーサではない):
// - 生文字列(`#"…"#`)・3連クォートの複数行文字列は非対応
// - パラメータ型の総称引数(`Dictionary<K, V>` 等、山括弧の中にカンマを持つ形)は非対応
//   (山括弧はコード中で比較演算子とも紐付くため、意図的に深さ追跡の対象から外している)

import Foundation

public struct ProjectCommandEntry: Sendable, Encodable, Equatable {
    public let name: String
    /// CommandIndex と同じ流儀の呼び出し形(ラベル無しの引数は内部名・末尾クロージャは `{ }`)。
    /// `receiver == "FTElement"` の場合、呼び出し側は `select(...).\(signature)` の形で書く
    public let signature: String
    public let summary: String
    /// `extension <Type> { }` の直下メソッドなら `<Type>`(トップレベル関数なら nil)
    public let receiver: String?
    /// scenarios/ からの相対パス
    public let file: String
    public let line: Int

    public init(name: String, signature: String, summary: String, receiver: String?,
                file: String, line: Int) {
        self.name = name
        self.signature = signature
        self.summary = summary
        self.receiver = receiver
        self.file = file
        self.line = line
    }
}

public struct ProjectCommandScanResult: Sendable, Equatable {
    public let commands: [ProjectCommandEntry]
    public let warnings: [String]

    public init(commands: [ProjectCommandEntry], warnings: [String]) {
        self.commands = commands
        self.warnings = warnings
    }
}

public enum ProjectCommandIndex {

    /// `scenarios/` 配下を再帰走査(`_disabled/` は除外。`ScenarioFolders.swiftFiles` と同じ規律)。
    /// 読めないファイルは黙って除く
    public static func scan(project: TestProject) -> ProjectCommandScanResult {
        let base = project.scenariosDir.standardizedFileURL
        var commands: [ProjectCommandEntry] = []
        var warnings: [String] = []
        for url in ScenarioFolders.swiftFiles(under: project.scenariosDir).sorted(by: {
            $0.path < $1.path
        }) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = relativePath(of: url, base: base)
            let result = scan(source: text, file: relative)
            commands.append(contentsOf: result.commands)
            warnings.append(contentsOf: result.warnings)
        }
        // 組み込みコマンドとの名前衝突は「気づかず影を落とす」事故なので警告する
        let builtinNames = Set(DSLCommandIndex.all.map(\.name)).union(DSLCommandIndex.internalNames)
        for entry in commands where builtinNames.contains(entry.name) {
            warnings.append("\(entry.name) (\(entry.file):\(entry.line)) has the same name as a"
                + " built-in DSL command and will be confusing — rename it")
        }
        return ProjectCommandScanResult(commands: commands, warnings: warnings)
    }

    private static func relativePath(of url: URL, base: URL) -> String {
        let basePath = base.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(basePath + "/") {
            return String(path.dropFirst(basePath.count + 1))
        }
        return url.lastPathComponent
    }

    /// 1ファイル分の走査。`file` は結果に載せる相対パス表記(呼び出し側が決める)
    public static func scan(source: String, file: String) -> ProjectCommandScanResult {
        let chars = Array(source)
        let kinds = classify(chars)
        let lineOf = lineNumbers(chars)
        let receiverAt = receivers(chars, kinds: kinds)

        var commands: [ProjectCommandEntry] = []
        var warnings: [String] = []
        let marker = Array("@FTCommand")
        var i = 0
        while i < chars.count {
            guard i + marker.count <= chars.count, kinds[i] == .code,
                  matches(chars, at: i, marker) else { i += 1; continue }
            let after = i + marker.count
            // "@FTCommandX" のような別名の誤検出を避ける
            if after < chars.count, isIdentifierChar(chars[after]) { i += 1; continue }
            let attrLine = lineOf[i]

            var cursor = after
            skipTrivia(chars, kinds, &cursor)
            guard cursor < chars.count, chars[cursor] == "(" else {
                warnings.append("@FTCommand at \(file):\(attrLine) is missing (\"summary\") — ignored")
                i = after
                continue
            }
            cursor += 1
            skipTrivia(chars, kinds, &cursor)
            guard cursor < chars.count, chars[cursor] == "\"" else {
                warnings.append("@FTCommand at \(file):\(attrLine) needs a non-empty string"
                    + " literal summary — ignored")
                i = after
                continue
            }
            guard let (summaryRaw, afterString) = readStringLiteral(chars, from: cursor) else {
                warnings.append("@FTCommand at \(file):\(attrLine) has an unterminated string"
                    + " literal — ignored")
                i = cursor
                continue
            }
            cursor = afterString
            skipTrivia(chars, kinds, &cursor)
            guard cursor < chars.count, chars[cursor] == ")" else {
                warnings.append("@FTCommand at \(file):\(attrLine) takes only a single string"
                    + " summary — ignored")
                i = cursor
                continue
            }
            cursor += 1
            let summary = summaryRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else {
                warnings.append("@FTCommand at \(file):\(attrLine) has an empty summary — ignored")
                i = cursor
                continue
            }

            guard let decl = parseFollowingFunc(chars, kinds, lineOf, receiverAt, from: cursor) else {
                warnings.append("@FTCommand at \(file):\(attrLine) is not followed by a func"
                    + " declaration — ignored")
                i = cursor
                continue
            }

            if decl.isPrivate {
                warnings.append("\(decl.name) (\(file):\(decl.line)) is private and cannot be"
                    + " called from scenarios")
            } else {
                commands.append(ProjectCommandEntry(
                    name: decl.name, signature: decl.signature, summary: summary,
                    receiver: decl.receiver, file: file, line: decl.line))
            }
            i = decl.endIndex
        }
        return ProjectCommandScanResult(commands: commands, warnings: warnings)
    }

    // MARK: - 文字種の分類(コメント / 文字列 / コード)

    enum CharKind: Equatable { case code, string, comment }

    /// Swift ソースを1文字(Character)ごとに分類する。エスケープされた `"` と文字列内挿入
    /// `\(...)` は素直に扱う(内挿の中身は `.code` として再帰的に見る)
    static func classify(_ chars: [Character]) -> [CharKind] {
        var kinds = [CharKind](repeating: .code, count: chars.count)
        enum Mode { case code, lineComment, blockComment, string }
        var mode: Mode = .code
        var blockDepth = 0
        // 文字列内挿入 \(...) の間だけ .code へ戻すための括弧深さ(0 なら文字列そのものの中)
        var interpDepth = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch mode {
            case .code:
                if interpDepth > 0 {
                    if c == "\"" {
                        // 内挿中のネストした文字列はざっくり飛ばす(括弧は数えない)
                        kinds[i] = .string
                        i += 1
                        while i < chars.count {
                            kinds[i] = .string
                            if chars[i] == "\\", i + 1 < chars.count {
                                kinds[i + 1] = .string
                                i += 2
                                continue
                            }
                            if chars[i] == "\"" { i += 1; break }
                            i += 1
                        }
                        continue
                    }
                    if c == "(" { interpDepth += 1 }
                    else if c == ")" {
                        interpDepth -= 1
                        kinds[i] = .string
                        i += 1
                        if interpDepth == 0 { mode = .string }
                        continue
                    }
                    kinds[i] = .code
                    i += 1
                    continue
                }
                if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    kinds[i] = .comment; kinds[i + 1] = .comment
                    mode = .lineComment; i += 2; continue
                }
                if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    kinds[i] = .comment; kinds[i + 1] = .comment
                    mode = .blockComment; blockDepth = 1; i += 2; continue
                }
                if c == "\"" {
                    kinds[i] = .string
                    mode = .string
                    i += 1
                    continue
                }
                kinds[i] = .code
                i += 1
            case .lineComment:
                kinds[i] = .comment
                if c == "\n" { mode = .code }
                i += 1
            case .blockComment:
                kinds[i] = .comment
                if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    kinds[i + 1] = .comment; blockDepth += 1; i += 2; continue
                }
                if c == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    kinds[i + 1] = .comment; blockDepth -= 1; i += 2
                    if blockDepth == 0 { mode = .code }
                    continue
                }
                i += 1
            case .string:
                kinds[i] = .string
                if c == "\\", i + 1 < chars.count {
                    if chars[i + 1] == "(" {
                        kinds[i + 1] = .code
                        interpDepth = 1
                        mode = .code
                        i += 2
                        continue
                    }
                    kinds[i + 1] = .string
                    i += 2
                    continue
                }
                if c == "\"" { mode = .code; i += 1; continue }
                i += 1
            }
        }
        return kinds
    }

    /// 各文字位置の行番号(1始まり)
    static func lineNumbers(_ chars: [Character]) -> [Int] {
        var lines = [Int](repeating: 1, count: chars.count)
        var line = 1
        for i in 0..<chars.count {
            lines[i] = line
            if chars[i] == "\n" { line += 1 }
        }
        return lines
    }

    /// 各文字位置が、直接 `extension <Type> { }` の本体直下にあるなら `<Type>`(それ以外は nil)。
    /// `class`/`struct`/`enum`/`protocol`/`actor` の本体や、更にネストした型の内側は nil に倒す
    /// (「トップレベル、または extension のメソッド」だけを受ける枠)
    enum ReceiverScope { case extensionBody(String); case other }

    static func receivers(_ chars: [Character], kinds: [CharKind]) -> [String?] {
        var result = [String?](repeating: nil, count: chars.count)
        var stack: [ReceiverScope] = []
        func currentReceiver() -> String? {
            guard case .extensionBody(let name)? = stack.last else { return nil }
            return name
        }
        var pendingKeyword: String?
        var pendingTypeName: String?
        var i = 0
        while i < chars.count {
            guard kinds[i] == .code else { i += 1; continue }
            let c = chars[i]
            if c == "{" {
                result[i] = currentReceiver()
                if let keyword = pendingKeyword {
                    if keyword == "extension", let type = pendingTypeName {
                        stack.append(.extensionBody(type))
                    } else {
                        stack.append(.other)
                    }
                } else {
                    stack.append(.other)
                }
                pendingKeyword = nil
                pendingTypeName = nil
                i += 1
                continue
            }
            if c == "}" {
                result[i] = currentReceiver()
                if !stack.isEmpty { stack.removeLast() }
                pendingKeyword = nil
                pendingTypeName = nil
                i += 1
                continue
            }
            result[i] = currentReceiver()
            if isIdentifierStart(c) {
                let start = i
                var j = i + 1
                while j < chars.count, kinds[j] == .code, isIdentifierChar(chars[j]) { j += 1 }
                let word = String(chars[start..<j])
                switch word {
                case "extension", "class", "struct", "enum", "protocol", "actor":
                    pendingKeyword = word
                    pendingTypeName = nil
                    var k = j
                    skipWhitespaceOnly(chars, kinds, &k)
                    if k < chars.count, kinds[k] == .code, isIdentifierStart(chars[k]) {
                        var m = k + 1
                        while m < chars.count, kinds[m] == .code, isIdentifierChar(chars[m]) { m += 1 }
                        pendingTypeName = String(chars[k..<m])
                    }
                case "func", "var", "let", "init":
                    // 次の { が来るまでに func/var/let/init を挟んだら、その { は型の直下ではない
                    // (計算プロパティの getter/setter 等)。pendingKeyword は "その直後の { は
                    // 型ヘッダのもの" を示すだけなので、ここでクリアして安全側に倒す
                    pendingKeyword = nil
                    pendingTypeName = nil
                default:
                    break
                }
                i = j
                continue
            }
            i += 1
        }
        return result
    }

    // MARK: - `@FTCommand(...)` に続く `func` 宣言の解析

    struct FuncDecl {
        let name: String
        let signature: String
        let receiver: String?
        let isPrivate: Bool
        let line: Int
        /// 宣言(本体の開始 `{` の直後、または `;`/改行)より後の走査再開位置
        let endIndex: Int
    }

    static let modifierKeywords: Set<String> = [
        "public", "private", "fileprivate", "internal", "package", "open",
        "static", "final", "mutating", "nonmutating", "override", "convenience",
        "dynamic", "lazy", "weak", "unowned", "class", "required", "indirect",
        "nonisolated", "distributed", "borrowing", "consuming",
    ]

    static func parseFollowingFunc(_ chars: [Character], _ kinds: [CharKind], _ lineOf: [Int],
                                   _ receiverAt: [String?], from start: Int) -> FuncDecl? {
        var cursor = start
        var isPrivate = false
        while true {
            skipTrivia(chars, kinds, &cursor)
            guard cursor < chars.count else { return nil }
            if chars[cursor] == "@" {
                // 他の属性(@discardableResult 等)。識別子 + 任意の引数リストを飛ばす
                var j = cursor + 1
                guard j < chars.count, isIdentifierStart(chars[j]) else { return nil }
                j += 1
                while j < chars.count, kinds[j] == .code, isIdentifierChar(chars[j]) { j += 1 }
                skipWhitespaceOnly(chars, kinds, &j)
                if j < chars.count, kinds[j] == .code, chars[j] == "(" {
                    guard let close = matchingParen(chars, kinds, openAt: j) else { return nil }
                    j = close + 1
                }
                cursor = j
                continue
            }
            guard isIdentifierStart(chars[cursor]) else { return nil }
            var j = cursor + 1
            while j < chars.count, kinds[j] == .code, isIdentifierChar(chars[j]) { j += 1 }
            let word = String(chars[cursor..<j])
            if word == "func" { cursor = j; break }
            if modifierKeywords.contains(word) {
                if word == "private" || word == "fileprivate" { isPrivate = true }
                cursor = j
                continue
            }
            // 知らない語 = func 宣言ではない(var/class 等)
            return nil
        }

        let funcKeywordEnd = cursor
        skipTrivia(chars, kinds, &cursor)
        guard cursor < chars.count else { return nil }
        let nameStart = cursor
        if chars[cursor] == "`" {
            // `default` のような予約語の名前。呼び出し側もバッククォートが要るので名前ごと残す
            cursor += 1
            guard cursor < chars.count, isIdentifierStart(chars[cursor]) else { return nil }
            while cursor < chars.count, kinds[cursor] == .code, isIdentifierChar(chars[cursor]) { cursor += 1 }
            guard cursor < chars.count, chars[cursor] == "`" else { return nil }
            cursor += 1
        } else {
            guard isIdentifierStart(chars[cursor]) else { return nil }
            while cursor < chars.count, kinds[cursor] == .code, isIdentifierChar(chars[cursor]) { cursor += 1 }
        }
        let name = String(chars[nameStart..<cursor])

        skipWhitespaceOnly(chars, kinds, &cursor)
        // ジェネリック節 <...> を飛ばす(func 名の直後に限るので山括弧の素朴な深さ数えで安全)
        if cursor < chars.count, kinds[cursor] == .code, chars[cursor] == "<" {
            var depth = 0
            while cursor < chars.count {
                if kinds[cursor] == .code {
                    if chars[cursor] == "<" { depth += 1 }
                    else if chars[cursor] == ">" {
                        depth -= 1
                        if depth == 0 { cursor += 1; break }
                    }
                }
                cursor += 1
            }
        }
        skipTrivia(chars, kinds, &cursor)
        guard cursor < chars.count, kinds[cursor] == .code, chars[cursor] == "(" else { return nil }
        let paramsOpen = cursor
        guard let paramsClose = matchingParen(chars, kinds, openAt: paramsOpen) else { return nil }
        let rawParams = String(chars[(paramsOpen + 1)..<paramsClose])
        let params = splitTopLevel(Array(rawParams), kinds: Array(kinds[(paramsOpen + 1)..<paramsClose]))
            .map { parseParam(Array($0)) }

        // 本体(または `throws`/`async`/`->戻り値型` の効果指定)の直前までを消費して
        // 呼び出し側の走査再開位置を決める。ここでの詳細な効果指定の解釈は不要 —— 次の
        // `{`(本体開始)まで進めば十分(本体を持たない宣言は無い前提。プロトコル内は対象外)
        var after = paramsClose + 1
        while after < chars.count {
            if kinds[after] == .code, chars[after] == "{" { break }
            after += 1
        }

        let receiver = receiverAt[min(funcKeywordEnd, receiverAt.count - 1)]
        let signature = renderSignature(name: name, params: params)
        return FuncDecl(name: name, signature: signature, receiver: receiver,
                        isPrivate: isPrivate, line: lineOf[nameStart], endIndex: after)
    }

    struct Param {
        let externalLabel: String?  // nil なら `_`(無ラベル)
        let internalName: String
        let isOptional: Bool
        let isClosure: Bool
    }

    static func parseParam(_ raw: [Character]) -> Param {
        let kinds = classify(raw)  // パラメータ片は元ソースの部分文字列なのでコメント/文字列は再分類できる
        // 先頭のコロン(名前部と型部の境界)を depth 0 で探す
        guard let colonIndex = topLevelIndex(of: ":", in: raw, kinds: kinds) else {
            // コロンが無い(異常系)。丸ごと内部名として扱う
            let text = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return Param(externalLabel: nil, internalName: text.isEmpty ? "_" : text,
                        isOptional: false, isClosure: false)
        }
        let namesPart = String(raw[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let names = namesPart.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let external: String?
        let internalName: String
        if names.count >= 2 {
            external = names[0] == "_" ? nil : names[0]
            internalName = names[1]
        } else if names.count == 1 {
            external = names[0] == "_" ? nil : names[0]
            internalName = names[0]
        } else {
            external = nil
            internalName = "_"
        }

        var typeChars = Array(raw[(colonIndex + 1)...])
        let typeKinds = classify(typeChars)
        // 既定値(トップレベルの `=`)より前で型を打ち切る
        if let eqIndex = topLevelIndex(of: "=", in: typeChars, kinds: typeKinds) {
            typeChars = Array(typeChars[..<eqIndex])
        }
        let typeText = String(typeChars).trimmingCharacters(in: .whitespacesAndNewlines)
        let isOptional = typeText.hasSuffix("?")
        let isClosure = typeText.contains("->")
        return Param(externalLabel: external, internalName: internalName,
                    isOptional: isOptional, isClosure: isClosure)
    }

    /// CommandIndex と同じ流儀で描画する: 無ラベル引数はその内部名(Optional なら `?` を添える)、
    /// 有ラベル引数は `label:`。末尾がクロージャ型なら括弧の外へ出し ` { }` として表す
    /// (非クロージャ引数が無ければ丸ごと括弧を省く。built-in の `scenario { }` 等と同じ形)
    static func renderSignature(name: String, params: [Param]) -> String {
        var nonClosure = params
        var trailingClosure = false
        if let last = nonClosure.last, last.isClosure {
            nonClosure.removeLast()
            trailingClosure = true
        }
        let tokens = nonClosure.map { param -> String in
            if let external = param.externalLabel {
                return "\(external):"
            }
            return param.internalName + (param.isOptional ? "?" : "")
        }
        var result: String
        if tokens.isEmpty {
            result = trailingClosure ? name : "\(name)()"
        } else {
            result = "\(name)(\(tokens.joined(separator: ", ")))"
        }
        if trailingClosure { result += " { }" }
        return result
    }

    // MARK: - 低水準ヘルパー

    static func matches(_ chars: [Character], at index: Int, _ pattern: [Character]) -> Bool {
        guard index + pattern.count <= chars.count else { return false }
        for k in 0..<pattern.count where chars[index + k] != pattern[k] { return false }
        return true
    }

    static func isIdentifierStart(_ c: Character) -> Bool {
        c == "_" || c.isLetter
    }

    static func isIdentifierChar(_ c: Character) -> Bool {
        c == "_" || c.isLetter || c.isNumber
    }

    /// 空白・改行・コメントを読み飛ばす(kind-aware。文字列の中では止まる)
    static func skipTrivia(_ chars: [Character], _ kinds: [CharKind], _ cursor: inout Int) {
        while cursor < chars.count {
            if kinds[cursor] == .comment || chars[cursor].isWhitespace { cursor += 1; continue }
            break
        }
    }

    /// 空白・改行だけを読み飛ばす(コメントには踏み込まない — 呼び出し元がコメントを
    /// 「ここで見つけた語」を壊さないよう明示的に使う箇所専用)
    static func skipWhitespaceOnly(_ chars: [Character], _ kinds: [CharKind], _ cursor: inout Int) {
        while cursor < chars.count, kinds[cursor] == .code, chars[cursor].isWhitespace { cursor += 1 }
    }

    /// `"` から始まる文字列リテラルを読み、(デコード済みの中身, 閉じ `"` の次の位置) を返す。
    /// `\"` `\\` `\n` `\t` を展開し、それ以外の `\x` は `x` へ簡略化する
    static func readStringLiteral(_ chars: [Character], from quoteIndex: Int) -> (String, Int)? {
        var cursor = quoteIndex + 1
        var out: [Character] = []
        while cursor < chars.count {
            let c = chars[cursor]
            if c == "\\", cursor + 1 < chars.count {
                switch chars[cursor + 1] {
                case "\"": out.append("\""); cursor += 2; continue
                case "\\": out.append("\\"); cursor += 2; continue
                case "n": out.append("\n"); cursor += 2; continue
                case "t": out.append("\t"); cursor += 2; continue
                default: out.append(chars[cursor + 1]); cursor += 2; continue
                }
            }
            if c == "\"" { return (String(out), cursor + 1) }
            out.append(c)
            cursor += 1
        }
        return nil
    }

    /// `openAt` にある `(`/`[`/`{` に対応する閉じ括弧の位置(kind-aware。文字列・コメントの中は数えない)
    static func matchingParen(_ chars: [Character], _ kinds: [CharKind], openAt: Int) -> Int? {
        guard openAt < chars.count else { return nil }
        var depth = 0
        var i = openAt
        while i < chars.count {
            if kinds[i] == .code {
                switch chars[i] {
                case "(", "[", "{": depth += 1
                case ")", "]", "}":
                    depth -= 1
                    if depth == 0 { return i }
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    /// トップレベル(深さ0)のカンマで分割する。`(`/`[`/`{` は深さを数え、文字列・コメントは無視
    static func splitTopLevel(_ chars: [Character], kinds: [CharKind]) -> [String] {
        var parts: [String] = []
        var depth = 0
        var start = 0
        var i = 0
        while i < chars.count {
            if kinds[i] == .code {
                switch chars[i] {
                case "(", "[", "{": depth += 1
                case ")", "]", "}": depth -= 1
                case ",":
                    if depth == 0 {
                        parts.append(String(chars[start..<i]))
                        start = i + 1
                    }
                default: break
                }
            }
            i += 1
        }
        let tail = String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 深さ0で最初に見つかる文字の位置(文字列・コメントの中、および `(`/`[`/`{` の内側は無視)
    static func topLevelIndex(of target: Character, in chars: [Character], kinds: [CharKind]) -> Int? {
        var depth = 0
        for i in 0..<chars.count {
            guard kinds[i] == .code else { continue }
            switch chars[i] {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            default:
                if depth == 0, chars[i] == target { return i }
            }
        }
        return nil
    }
}
