import Foundation
import XCTest

/// 契約: 生/死/不明・空き/占有/不明のような3値以上を返す判定は、呼び手が「不明」を確定値へ
/// 畳んではいけない(CLAUDE.md「不明と確定値を混ぜない」)。ここはこの規律をソース走査で
/// **近似**する回帰ゲート。
///
/// **検出する形(この2つだけ)**:
///  (a) 対象の型を switch する箇所に `default:` がある —— 新しい case が増えても・既存の case を
///      見落としても、コンパイルエラーにならず黙って一括りにされる
///  (b) 同じ switch の1つの `case` 節が、対象の型の case 名を2つ以上まとめて書いている
///      (`case .a, .b:` の形)。対象の4型はどの2値を混ぜても対処が逆になりうる組を持つので、
///      1本の枝へ畳むこと自体を機械的に禁じる
///
/// **検出できないことにした形**(「出ない」を「畳んでいない」の証拠にしないこと):
///  - switch を使わない畳み込み(`guard`/`if` の `==`/`||` チェーン。例:
///    `probe == .transportFailed || probe == .notBound` は「どちらも本当に消えている」という
///    正しい結合もあるので、テキストだけでは善悪を区別できず対象外)
///  - `??`/`?? true`/`?? false` による Optional の強制。安全側(occupancy の `mine: Bool = false`
///    のような「不明を保守的な既定へ倒す」)への畳み込みは規律そのものであることが多く、
///    方向の善悪をソース走査だけでは判定できないので対象外
///  - `if case .x = y { … } else { … }` の部分パターンマッチ(else 節が「x 以外全部」を束ねるが、
///    正当/不当をテキストだけで区別できない)
///  - 複数物理行にまたがる `case` 節(`case .a,\n .b:` のように改行を挟むもの。`caseHead` は
///    同一行で `:` が閉じない場合その節を読み捨てる)
///  - コメント除去は行頭からではなく `//` 以降を機械的に切り捨てるだけ(LiveControlExitParityTests /
///    ProcessLivenessSourceScanTests と同じ簡略化)。文字列リテラル中の `//` を誤って
///    切り落とすことがある
///  - Tests/ は対象外(実際の呼び手 = Sources/ だけを見る)
///  - 免除キーは `file + switch 主語式`。**同一ファイルに同じ主語式の switch が複数あると
///    免除が両方に効いてしまう**(現状ゼロ免除なので未発生。免除を足すときは注意)
///
/// **この走査は「出れば正しい」であって「出なければ不明を畳んでいない」ではない**
/// (fm-occlusion.md の OCR 段と同じ立場)。
///
/// **覆う判定**(enum を switch する形のものだけ):
///  ① `FTBridgeClient.BridgeDiscovery.StatusProbe`(answered/timedOut/transportFailed/notBound。
///     どの2値も対処が逆になりうる4値。bridge-provision.md)
///  ② `FTRemote.RemoteDispatchLock.Probe`(absent/held。`Probe?` の `nil` が「読めなかった=不明」で
///     `.absent`(空き)と区別される)
///  ③ `ApiLiveCommand.PortIdentity`(mine/mismatch/silent)
///  ④ `MCPServer.ExplicitPortIdentity`(confirmedMatch/confirmedMismatch/unknown)
///
/// **覆えない判定(ここを代替の型で埋めない)** —— 同じ規律に属するが不明の表し方が違うので、
/// この走査の (a)(b) では原理的に検出できない。塞ぐなら別の仕組みが要る:
///  - **`FTCore.FMLiveness`**: `State` は alive/dead の2値で、**不明は `Verdict?` の nil**。
///    畳む形は `?? .dead` のような Optional の強制 = (c) に当たる
///  - **`FTRemote.HostOccupancy`**: `held: Bool` を持つ平坦な構造体で switch されない。
///    「不明(observed:false)を空きに畳まない」を実際に守っているのは**拡張側の TypeScript**
///    (`vscode-fleetest/src/machineLockModel.ts` の `lock.held || !lock.observed`)なので、
///    縛るなら npm test 側の走査になる(Swift からは届かない)
final class UnknownNotFoldedScanTests: XCTestCase {

    private struct JudgementSpec {
        let name: String
        /// この型の case 名の集合。switch の case 節から拾った識別子のうち、ここに含まれるものだけを
        /// 「この型に属する」とみなす
        let caseNames: Set<String>
        /// この個数以上一致してはじめて、その switch をこの型に**帰属**させる
        /// (`.unknown`/`.held`/`.silent` 等は他の型でも使われる名前なので、1個の一致だけでは
        /// 誤帰属しうる。2個以上を要求して衝突を避ける)
        let minMatches: Int
    }

    private static let specs: [JudgementSpec] = [
        JudgementSpec(
            name: "BridgeDiscovery.StatusProbe",
            caseNames: ["answered", "timedOut", "transportFailed", "notBound"], minMatches: 2),
        JudgementSpec(
            name: "RemoteDispatchLock.Probe",
            caseNames: ["absent", "held"], minMatches: 2),
        JudgementSpec(
            name: "ApiLiveCommand.PortIdentity",
            caseNames: ["mine", "mismatch", "silent"], minMatches: 2),
        JudgementSpec(
            name: "MCPServer.ExplicitPortIdentity",
            caseNames: ["confirmedMatch", "confirmedMismatch", "unknown"], minMatches: 2),
    ]

    /// 免除(`"<file>::<switch 主語式>"`)。**足すときは理由を1行で書くこと**。
    /// 現時点で免除は無い —— 既存の全呼び出しが規律を守っている(このテストを書いた時点の調査)
    private static let exempt: Set<String> = []

    // MARK: - 走査の部品

    private struct SwitchBlock {
        let file: String
        /// "switch" の直後から "{" の直前までの主語式(トリム済み)
        let header: String
        let body: String
    }

    private struct Offender {
        let file: String
        let header: String
        let judgement: String
        let reason: String
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
    }

    /// 行頭からではなく `//` 以降を切り捨てる(既存の走査系テストと同じ簡略化。ファイル冒頭の
    /// 「検出できないことにした形」参照)
    private static func stripComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[..<range.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// **プロセス内で1回だけ Sources/ を読んで切り出す**(3つのテストメソッドがそれぞれ走査し
    /// 直すと、ファイル I/O と波括弧の char-by-char 走査を毎回 3〜4 重に払う。
    /// ProcessLivenessSourceScanTests と同じ `static let` キャッシュの流儀)
    private static let cachedFiles: [(file: String, source: String)] = readSwiftFiles()
    private static let cachedBlocks: [SwitchBlock] = cachedFiles.flatMap {
        switchBlocks(in: $0.source, file: $0.file)
    }

    private static func readSwiftFiles() -> [(file: String, source: String)] {
        let sourcesRoot = repoRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var result: [(String, String)] = []
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            guard url.pathExtension == "swift" else { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = "Sources" + url.path.dropFirst(sourcesRoot.path.count)
            result.append((relative, stripComments(raw)))
        }
        return result
    }

    /// `switch <expr> { … }` を波括弧の深さで切り出す(KillCallSiteOwnershipGuardTests.functions(in:)
    /// と同じ手法)。**行頭(前置の空白のみ)の `switch` だけを対象にする** ——
    /// 文字列リテラル中の `"switch"`(UI ロール名などに実在する)を主語式の開始と誤認しないため
    private static func switchBlocks(in source: String, file: String) -> [SwitchBlock] {
        var results: [SwitchBlock] = []
        let pattern = try! NSRegularExpression(pattern: #"^[ \t]*switch\b"#, options: [.anchorsMatchLines])
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches {
            guard let matchRange = Range(match.range, in: source) else { continue }
            guard let braceStart = source.range(
                of: "{", range: matchRange.upperBound..<source.endIndex) else { continue }
            let header = String(source[matchRange.upperBound..<braceStart.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var depth = 0
            var idx = braceStart.lowerBound
            var end: String.Index?
            while idx < source.endIndex {
                let ch = source[idx]
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { end = idx; break }
                }
                idx = source.index(after: idx)
            }
            guard let end else { continue }
            let bodyStart = source.index(after: braceStart.lowerBound)
            results.append(SwitchBlock(file: file, header: header, body: String(source[bodyStart..<end])))
        }
        return results
    }

    /// 波括弧の深さが0の `case`/`default` 節だけを拾う(ネストした switch/if/closure の中の
    /// `case` は無視する)。1つの `case` 節が持つ識別子の並び(comma 区切り)を配列で返す
    private static func caseArms(in body: String) -> (arms: [[String]], hasDefault: Bool) {
        var depth = 0
        var arms: [[String]] = []
        var hasDefault = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if depth == 0 {
                if trimmed.hasPrefix("default:") || trimmed.hasPrefix("default :") {
                    hasDefault = true
                } else if trimmed.hasPrefix("case "), let head = caseHead(trimmed) {
                    arms.append(splitTopLevel(head, by: ",").compactMap(leadingIdentifier))
                }
            }
            for ch in line {
                if ch == "{" { depth += 1 }
                if ch == "}" { depth -= 1 }
            }
        }
        return (arms, hasDefault)
    }

    /// トリム済みの `case …:` 行から `case` を落とし、丸括弧/角括弧の深さ0で最初に現れる `:` までを
    /// 返す(その後ろに本文が続く1行 `case .x: return y` の形も扱える)。同一行で閉じなければ nil
    /// (複数行にまたがる case は検出対象外 —— ファイル冒頭の限界を参照)
    private static func caseHead(_ trimmedLine: String) -> String? {
        var text = Substring(trimmedLine)
        text.removeFirst("case".count)
        var depth = 0
        var result = ""
        for ch in text {
            if ch == "(" || ch == "[" { depth += 1 }
            if ch == ")" || ch == "]" { depth -= 1 }
            if ch == ":", depth == 0 { return result }
            result.append(ch)
        }
        return nil
    }

    private static func splitTopLevel(_ text: String, by separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for ch in text {
            if ch == "(" || ch == "[" { depth += 1 }
            if ch == ")" || ch == "]" { depth -= 1 }
            if ch == separator, depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    /// `.foo(let x)` / `foo(let x)` / `.foo` から先頭の識別子(`foo`)だけを取り出す
    private static func leadingIdentifier(_ text: String) -> String? {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.first == "." { s = s.dropFirst() }
        var ident = ""
        for ch in s {
            guard ch.isLetter || ch.isNumber || ch == "_" else { break }
            ident.append(ch)
        }
        return ident.isEmpty ? nil : ident
    }

    // MARK: - 判定

    private static func offenders() -> [Offender] {
        var found: [Offender] = []
        for block in cachedBlocks {
            let (arms, hasDefault) = caseArms(in: block.body)
            let allIdents = Set(arms.flatMap { $0 })
            for spec in specs {
                guard allIdents.intersection(spec.caseNames).count >= spec.minMatches else { continue }
                guard !exempt.contains("\(block.file)::\(block.header)") else { continue }
                if hasDefault {
                    found.append(Offender(
                        file: block.file, header: block.header, judgement: spec.name,
                        reason: "default: が \(spec.name) の case を一括りにしている"))
                }
                for arm in arms {
                    let armMatched = Set(arm).intersection(spec.caseNames)
                    guard armMatched.count >= 2 else { continue }
                    found.append(Offender(
                        file: block.file, header: block.header, judgement: spec.name,
                        reason: "1つの case 節が \(spec.name) の "
                            + "\(armMatched.sorted().joined(separator: ", ")) を1本の枝へ結合している"))
                }
            }
        }
        return found
    }

    // MARK: - テスト

    /// 走査が Sources/ に実際に届いていることの確認(空文字を検索すると何を書いても通る罠と同じ)
    func testScanReachesSources() {
        let files = Self.cachedFiles
        XCTAssertGreaterThan(files.count, 50, "Sources/ を読めていない")
        XCTAssertTrue(files.contains { $0.file.hasSuffix("BridgeDiscovery.swift") })
        XCTAssertFalse(Self.cachedBlocks.isEmpty, "switch 文を1つも切り出せていない")
    }

    /// 各判定を、少なくとも1つの実在の switch が正しく踏んでいることの確認。
    /// **これが無いと、case 名がずれていたり走査が壊れていても「offenders が空」で静かに通る**
    /// (常に何も検出しない壊れた検知を「陰性(誤検知0)」と区別できないのと同型)
    func testEachJudgementHasAtLeastOneAttributedSwitch() {
        var attributed: [String: Int] = [:]
        for block in Self.cachedBlocks {
            let (arms, _) = Self.caseArms(in: block.body)
            let allIdents = Set(arms.flatMap { $0 })
            for spec in Self.specs where allIdents.intersection(spec.caseNames).count >= spec.minMatches {
                attributed[spec.name, default: 0] += 1
            }
        }
        for spec in Self.specs {
            XCTAssertGreaterThanOrEqual(attributed[spec.name] ?? 0, 1,
                "\(spec.name) を switch している既存コードが1つも見つからない —— 走査が壊れているか"
                + "対象の case 名がずれている(このテスト自体が壊れている合図)")
        }
    }

    /// 本体: 新しい呼び手が `default:` または comma 結合で不明/対処違いの case を畳んだら落ちる
    func testNoDefaultOrCombinedCaseFoldsAJudgement() {
        let found = Self.offenders()
        XCTAssertTrue(found.isEmpty, found.map {
            "\($0.file) [switch \($0.header) {] (\($0.judgement)): \($0.reason)"
        }.joined(separator: "\n"))
    }
}
