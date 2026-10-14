import Foundation

/// 展開に使う辞書。親の環境変数は意図して含めない(compose.yaml の `${…}` 経由で親のトークンが
/// コンテナへ渡るのを防ぐ)。同じ名前が両方にあれば secrets が勝つ。
public struct ExpansionDictionaries: Sendable {
    public var secrets: [String: String]
    public var plain: [String: String]

    public init(secrets: [String: String] = [:], plain: [String: String] = [:]) {
        self.secrets = secrets
        self.plain = plain
    }
}

public struct Expanded: Sendable, Equatable {
    public let value: String
    /// 展開の過程で実際に使った秘密の名前。展開済みの文字列を走査して復元しない
    /// (`PASSWORD=${TOKEN}` が値になった時点で TOKEN は消え、秘密の値に含まれる `${OTHER}` を誤って拾う)。
    public let usedSecrets: Set<String>

    public init(value: String, usedSecrets: Set<String>) {
        self.value = value
        self.usedSecrets = usedSecrets
    }
}

/// compose の補間構文: `$VAR` `${VAR}` `${VAR:-d}` `${VAR-d}` `${VAR:?e}` `${VAR?e}` `$$`。
/// 既定値の中の入れ子は1段だけ。未定義で既定値も無ければ拒否する(compose は空にして警告するが、
/// 空のまま走ると原因の見えない失敗になる)。
public enum VariableExpansion {
    public static func expand(
        _ text: String,
        dictionaries: ExpansionDictionaries,
        allowSecrets: Bool,
        path: ComposePath
    ) -> Result<Expanded, ComposeRefusal> {
        var used = Set<String>()
        do {
            let value = try run(Array(text), dictionaries, allowSecrets, path, nesting: 0, used: &used)
            return .success(Expanded(value: value, usedSecrets: used))
        } catch let refusal as ComposeRefusal {
            return .failure(refusal)
        } catch {
            return .failure(.badSubstitution(path: path, detail: "unexpected error"))
        }
    }

    private static func isNameStart(_ c: Character) -> Bool {
        c == "_" || (c.isASCII && c.isLetter)
    }

    private static func isNameChar(_ c: Character) -> Bool {
        c == "_" || (c.isASCII && (c.isLetter || c.isNumber))
    }

    private static func run(
        _ chars: [Character], _ dict: ExpansionDictionaries, _ allowSecrets: Bool, _ path: ComposePath,
        nesting: Int, used: inout Set<String>
    ) throws -> String {
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "$" else {
                out.append(c)
                i += 1
                continue
            }
            guard i + 1 < chars.count else {
                throw ComposeRefusal.badSubstitution(path: path, detail: "'$' at the end of the value; write $$ for a literal dollar sign")
            }
            let next = chars[i + 1]
            if next == "$" {
                out.append("$")
                i += 2
            } else if next == "{" {
                var depth = 0
                var j = i + 2
                var close: Int?
                while j < chars.count {
                    if chars[j] == "$", j + 1 < chars.count, chars[j + 1] == "{" {
                        depth += 1
                        j += 2
                        continue
                    }
                    if chars[j] == "}" {
                        if depth == 0 {
                            close = j
                            break
                        }
                        depth -= 1
                    }
                    j += 1
                }
                guard let close else {
                    throw ComposeRefusal.badSubstitution(path: path, detail: "missing closing brace")
                }
                out += try braced(Array(chars[(i + 2)..<close]), dict, allowSecrets, path, nesting: nesting, used: &used)
                i = close + 1
            } else if isNameStart(next) {
                var j = i + 1
                var name = ""
                while j < chars.count, isNameChar(chars[j]) {
                    name.append(chars[j])
                    j += 1
                }
                guard let value = try lookup(name, dict, allowSecrets, path, used: &used) else {
                    throw ComposeRefusal.unsetVariable(path: path, name: name)
                }
                out += value
                i = j
            } else {
                throw ComposeRefusal.badSubstitution(path: path, detail: "'$' must be followed by a variable name or '{'; write $$ for a literal dollar sign")
            }
        }
        return out
    }

    private static func lookup(
        _ name: String, _ dict: ExpansionDictionaries, _ allowSecrets: Bool, _ path: ComposePath,
        used: inout Set<String>
    ) throws -> String? {
        if let secret = dict.secrets[name] {
            guard allowSecrets else { throw ComposeRefusal.secretInForbiddenField(path: path, name: name) }
            used.insert(name)
            return secret
        }
        return dict.plain[name]
    }

    private static func braced(
        _ content: [Character], _ dict: ExpansionDictionaries, _ allowSecrets: Bool, _ path: ComposePath,
        nesting: Int, used: inout Set<String>
    ) throws -> String {
        var name = ""
        var k = 0
        if k < content.count, isNameStart(content[k]) {
            while k < content.count, isNameChar(content[k]) {
                name.append(content[k])
                k += 1
            }
        }
        guard !name.isEmpty else {
            throw ComposeRefusal.badSubstitution(path: path, detail: "missing variable name in ${…}")
        }
        let rest = Array(content[k...])
        let value = try lookup(name, dict, allowSecrets, path, used: &used)
        if rest.isEmpty {
            guard let value else { throw ComposeRefusal.unsetVariable(path: path, name: name) }
            return value
        }
        let colon = rest[0] == ":"
        let opIndex = colon ? 1 : 0
        guard opIndex < rest.count, rest[opIndex] == "-" || rest[opIndex] == "?" else {
            throw ComposeRefusal.badSubstitution(path: path, detail: "unsupported operator after '\(name)'")
        }
        let isDefault = rest[opIndex] == "-"
        let operand = Array(rest[(opIndex + 1)...])
        let missing = value == nil || (colon && value?.isEmpty == true)
        if !missing, let value { return value }
        if isDefault {
            if nesting >= 1, operand.contains("$") {
                throw ComposeRefusal.badSubstitution(path: path, detail: "defaults nested more than one level deep are not supported")
            }
            return try run(operand, dict, allowSecrets, path, nesting: nesting + 1, used: &used)
        }
        let message = String(operand)
        throw ComposeRefusal.badSubstitution(
            path: path, detail: "required variable '\(name)' is not set" + (message.isEmpty ? "" : ": \(message)"))
    }
}

/// compose の `.env` の規則で読む。値の中の `${…}` は plain(それまでの行で定義した変数を含む)だけを見て、
/// 秘密を参照したら拒否する(`TAG=${TOKEN}` → `image: x/${TAG}` の間接参照を塞ぐ)。
public enum DotEnvFile {
    public static func parse(
        _ text: String,
        dictionaries: ExpansionDictionaries
    ) -> Result<[(key: String, value: String)], ComposeRefusal> {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        var result: [(key: String, value: String)] = []
        var defined: [String: String] = [:]
        var i = 0
        while i < lines.count {
            let lineNo = i + 1
            let path = ComposePath(".env line \(lineNo)")
            var line = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let eq = line.firstIndex(of: "=") else {
                return .failure(.invalidValue(path: path, reason: "expected KEY=VALUE"))
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let validKey = !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
            guard validKey else {
                return .failure(.invalidValue(path: path, reason: "invalid variable name"))
            }
            var rest = String(line[line.index(after: eq)...])
            while rest.first == " " || rest.first == "\t" { rest.removeFirst() }

            let value: String
            if rest.hasPrefix("'") {
                var body = String(rest.dropFirst())
                while !body.contains("'") {
                    guard i < lines.count else {
                        return .failure(.invalidValue(path: path, reason: "unterminated single quote"))
                    }
                    body += "\n" + lines[i]
                    i += 1
                }
                value = String(body[..<body.firstIndex(of: "'")!])
            } else if rest.hasPrefix("\"") {
                var body = String(rest.dropFirst())
                var decoded = decodeDoubleQuoted(body)
                while decoded == nil {
                    guard i < lines.count else {
                        return .failure(.invalidValue(path: path, reason: "unterminated double quote"))
                    }
                    body += "\n" + lines[i]
                    i += 1
                    decoded = decodeDoubleQuoted(body)
                }
                switch expandPlain(decoded ?? "", dictionaries, defined, path) {
                case .success(let text): value = text
                case .failure(let refusal): return .failure(refusal)
                }
            } else {
                var raw = rest
                if let hash = raw.range(of: " #") ?? raw.range(of: "\t#") { raw = String(raw[..<hash.lowerBound]) }
                switch expandPlain(raw.trimmingCharacters(in: .whitespaces), dictionaries, defined, path) {
                case .success(let text): value = text
                case .failure(let refusal): return .failure(refusal)
                }
            }
            defined[key] = value
            result.append((key: key, value: value))
        }
        return .success(result)
    }

    /// 閉じの `"` までを返す(エスケープ `\n \r \t \" \\` を解く)。閉じが無ければ nil。
    private static func decodeDoubleQuoted(_ body: String) -> String? {
        var out = ""
        var escaped = false
        for ch in body {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default:
                    out.append("\\")
                    out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return out
            } else {
                out.append(ch)
            }
        }
        return nil
    }

    private static func expandPlain(
        _ text: String, _ dictionaries: ExpansionDictionaries, _ defined: [String: String], _ path: ComposePath
    ) -> Result<String, ComposeRefusal> {
        let merged = ExpansionDictionaries(
            secrets: dictionaries.secrets,
            plain: dictionaries.plain.merging(defined) { _, newer in newer })
        switch VariableExpansion.expand(text, dictionaries: merged, allowSecrets: false, path: path) {
        case .success(let expanded): return .success(expanded.value)
        case .failure(.secretInForbiddenField(_, let name)): return .failure(.secretReferencedFromDotEnv(name: name))
        case .failure(let refusal): return .failure(refusal)
        }
    }
}
