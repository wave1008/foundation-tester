// ビルドの指紋と .dockerignore の照合。純粋関数(ファイルの列挙と stat は呼び手)。
// ファイルの中身は読まない: 同サイズ・同 mtime の中身だけの変更は拾わない(§17「ビルドとデータ投入の規則」)。
// 注意: FTCore にも同名の ServiceBuildFingerprint(Swift ビルドのスキップ判定)がある。FTServices の中では
// こちらが勝つが、両方を import するファイルでは曖昧になる。

import CryptoKit
import Foundation

public struct FileFact: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case file, directory, symlink }
    public var relativePath: String
    public var size: Int
    public var mtimeNanoseconds: Int64
    public var mode: UInt16
    public var kind: Kind
    public init(relativePath: String, size: Int, mtimeNanoseconds: Int64, mode: UInt16, kind: Kind) {
        self.relativePath = relativePath
        self.size = size
        self.mtimeNanoseconds = mtimeNanoseconds
        self.mode = mode
        self.kind = kind
    }
}

public struct FingerprintInputs: Sendable, Equatable {
    /// .dockerignore 適用後。順序は問わない。
    public var files: [FileFact]
    public var dockerfileContents: String
    public var args: [String: String]
    public var target: String?
    public var platform: String?
    public init(files: [FileFact], dockerfileContents: String, args: [String: String] = [:],
                target: String? = nil, platform: String? = nil) {
        self.files = files
        self.dockerfileContents = dockerfileContents
        self.args = args
        self.target = target
        self.platform = platform
    }
}

public enum ServiceBuildFingerprint {
    /// SHA-256 の hex 64 桁。欄の区切りは U+0000(パスにも引数にも現れない)。
    /// 集合の長さを先に書くので、欄の境界をずらした別の入力と同じ連結にならない。
    public static func compute(_ inputs: FingerprintInputs) -> String {
        let sep = "\u{0}"
        var parts: [String] = ["files", String(inputs.files.count)]
        // 辞書順は UTF-8 のバイト列で比べる(ロケールに依らない)
        for f in inputs.files.sorted(by: { Array($0.relativePath.utf8).lexicographicallyPrecedes(Array($1.relativePath.utf8)) }) {
            parts += [f.relativePath, String(f.size), String(f.mtimeNanoseconds), String(f.mode), f.kind.rawValue]
        }
        parts += ["dockerfile", inputs.dockerfileContents, "args", String(inputs.args.count)]
        for k in inputs.args.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            parts += [k, inputs.args[k] ?? ""]
        }
        parts += optional("target", inputs.target) + optional("platform", inputs.platform)
        let digest = SHA256.hash(data: Data(parts.joined(separator: sep).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// nil と空文字を区別する。
    private static func optional(_ label: String, _ value: String?) -> [String] {
        guard let value else { return [label, "-"] }
        return [label, "+", value]
    }
}

public enum DockerIgnore {
    public struct Rule: Sendable, Equatable {
        public var segments: [String]
        public var negated: Bool
        public init(segments: [String], negated: Bool) {
            self.segments = segments
            self.negated = negated
        }
    }

    public static func parse(_ text: String) -> [Rule] {
        var rules: [Rule] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var negated = false
            if line.hasPrefix("!") {
                negated = true
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            let segments = line.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
            if segments.isEmpty { continue }
            rules.append(Rule(segments: segments, negated: negated))
        }
        return rules
    }

    /// 最後に一致した規則が勝つ。パス自身か、その親のどれかが一致すれば一致(ディレクトリの配下)。
    /// 親が除外されて否定で再び含めるのは Docker と同じく規則の順で決まる。
    public static func isIgnored(_ relativePath: String, rules: [Rule]) -> Bool {
        let path = relativePath.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        if path.isEmpty { return false }
        if path == ["Dockerfile"] || path == [".dockerignore"] { return false }
        var ignored = false
        for rule in rules {
            let matched = (1...path.count).contains { n in
                matchSegments(rule.segments, 0, Array(path.prefix(n)), 0)
            }
            if matched { ignored = !rule.negated }
        }
        return ignored
    }

    private static func matchSegments(_ p: [String], _ i: Int, _ s: [String], _ j: Int) -> Bool {
        if i == p.count { return j == s.count }
        if p[i] == "**" {
            var k = j
            while k <= s.count {
                if matchSegments(p, i + 1, s, k) { return true }
                k += 1
            }
            return false
        }
        if j == s.count { return false }
        return glob(Array(p[i]), 0, Array(s[j]), 0) && matchSegments(p, i + 1, s, j + 1)
    }

    /// filepath.Match の文法(`*` `?` `[a-z]` `[^a-z]` `\x`)。1セグメント内だけなので `/` は跨がない。
    private static func glob(_ p: [Character], _ i: Int, _ s: [Character], _ j: Int) -> Bool {
        var i = i, j = j
        while i < p.count {
            switch p[i] {
            case "*":
                var k = j
                while k <= s.count {
                    if glob(p, i + 1, s, k) { return true }
                    k += 1
                }
                return false
            case "?":
                if j >= s.count { return false }
                i += 1; j += 1
            case "[":
                if j >= s.count { return false }
                guard let (ok, next) = matchClass(p, i, s[j]) else { return false }
                if !ok { return false }
                i = next; j += 1
            case "\\" where i + 1 < p.count:
                if j >= s.count || s[j] != p[i + 1] { return false }
                i += 2; j += 1
            default:
                if j >= s.count || s[j] != p[i] { return false }
                i += 1; j += 1
            }
        }
        return j == s.count
    }

    /// `p[start]` は "["。戻り値: (一致したか, 閉じ括弧の次の位置)。閉じていなければ nil(不一致扱い)。
    private static func matchClass(_ p: [Character], _ start: Int, _ c: Character) -> (Bool, Int)? {
        var i = start + 1
        var negate = false
        if i < p.count, p[i] == "^" || p[i] == "!" { negate = true; i += 1 }
        var matched = false
        var first = true
        while i < p.count {
            if p[i] == "]" && !first { return (matched != negate, i + 1) }
            first = false
            var lo = p[i]
            if lo == "\\", i + 1 < p.count { i += 1; lo = p[i] }
            var hi = lo
            if i + 2 < p.count, p[i + 1] == "-", p[i + 2] != "]" {
                hi = p[i + 2]
                i += 2
                if hi == "\\", i + 1 < p.count { i += 1; hi = p[i] }
            }
            if lo <= c && c <= hi { matched = true }
            i += 1
        }
        return nil
    }
}
