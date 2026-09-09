import XCTest
@testable import FTDSL

/// `fleetest api dsl-commands` が出す索引(Sources/FTCore/CommandIndex.swift)を**ソースと突き合わせる**。
/// 索引は手書きなので、これが無いとコマンドを足した瞬間に「載っていない = 存在しない」と
/// 読まれる嘘を配ることになる(索引の唯一の用途がコード生成前の存在確認なので致命的)。
final class CommandIndexSyncTests: XCTestCase {

    private var sourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTDSLTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("Sources/FTDSL")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: sourcesDir.appendingPathComponent(name), encoding: .utf8)
    }

    /// コマンド定義は `Commands*.swift` に分割されている(Commands / CommandsVerify /
    /// CommandsAppControl)。**名前を列挙せず接頭辞で拾う** —— 再分割で増えたファイルを
    /// 見落とすと「ソースにあるが索引に無い」の検出がそのファイルだけ黙って消える
    private func commandsSource() throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: sourcesDir.path)
            .filter { $0.hasPrefix("Commands") && $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 3, "コマンド定義ファイルの発見が壊れている: \(names)")
        return try names.map { try source($0) }.joined(separator: "\n")
    }

    /// 行頭 `public func 名前(` を拾う(トップレベルの自由関数だけ = 索引の対象)
    private func topLevelFunctions(in source: String) -> Set<String> {
        names(in: source, prefix: "public func ", anchoredToLineStart: true)
    }

    /// 行頭 `public var 名前:` を拾う(引数を取らないコマンド。lastElement)
    private func topLevelValues(in source: String) -> Set<String> {
        var found: Set<String> = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            guard text.hasPrefix("public var ") else { continue }
            let rest = text.dropFirst("public var ".count)
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let name = String(rest[rest.startIndex..<colon])
            if !name.isEmpty, !name.contains(" ") { found.insert(name) }
        }
        return found
    }

    private func names(in source: String, prefix: String, anchoredToLineStart: Bool) -> Set<String> {
        var found: Set<String> = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = anchoredToLineStart ? String(line) : line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(prefix) else { continue }
            let rest = text.dropFirst(prefix.count)
            guard let paren = rest.firstIndex(of: "(") else { continue }
            let name = String(rest[rest.startIndex..<paren])
            // `` `switch` `` のようなバッククォート名は索引の対象外(コマンドには無い)
            if !name.isEmpty, !name.contains(" ") { found.insert(name) }
        }
        return found
    }

    func testIndexCoversEveryCommand() throws {
        let commandsSource = try self.commandsSource()
        let commands = topLevelFunctions(in: commandsSource)
            .union(topLevelValues(in: commandsSource))
            .subtracting(DSLCommandIndex.internalNames)
        // this* は `public extension` の中のメンバ(各宣言に public は付かない)
        let thisAssertions = names(in: try source("ValueAssertions.swift"),
                                   prefix: "func this", anchoredToLineStart: false)
            .map { "this" + $0 }
        let declared = commands.union(thisAssertions)
        let indexed = Set(DSLCommandIndex.all.map(\.name))

        XCTAssertEqual(indexed.subtracting(declared), [],
                       "索引にあるがソースに無いコマンド(改名・削除の追随漏れ)")
        XCTAssertEqual(declared.subtracting(indexed), [],
                       "ソースにあるが索引に無いコマンド(CommandIndex.swift に追記する)")
    }

    /// chainable は `exist(...)` の戻り値に生えるメソッド集合(FTElement)と一致する。
    /// ズレると「繋げられる」と読んで書いたコードがコンパイルエラーになる
    func testChainableMatchesFTElementMethods() throws {
        let commandsSource = try self.commandsSource()
        guard let structRange = commandsSource.range(of: "public struct FTElement {") else {
            return XCTFail("FTElement の宣言が見つからない(索引の chainable を照合できない)")
        }
        // 構造体の終端は行頭 `}`(ネストしたメソッドの閉じ括弧はインデントされている)
        let body = commandsSource[structRange.upperBound...]
        let end = body.range(of: "\n}") ?? body.startIndex..<body.startIndex
        let element = String(body[body.startIndex..<end.lowerBound])

        let chainMethods = names(in: element, prefix: "public func ", anchoredToLineStart: false)
            .subtracting(DSLCommandIndex.chainOnlyNames)
        let indexedChainable = Set(DSLCommandIndex.all.filter(\.chainable).map(\.name))

        XCTAssertEqual(indexedChainable, chainMethods,
                       "索引の chainable と FTElement のメソッドがズレている")
    }

    func testEveryEntryIsFilledIn() {
        for command in DSLCommandIndex.all {
            XCTAssertFalse(command.signature.isEmpty, "\(command.name): signature が空")
            XCTAssertFalse(command.summary.isEmpty, "\(command.name): summary が空")
            XCTAssertTrue(command.signature.contains(command.name),
                          "\(command.name): signature が別のコマンドを指している")
        }
        XCTAssertEqual(Set(DSLCommandIndex.all.map(\.name)).count, DSLCommandIndex.all.count,
                       "索引に重複がある")
    }

    // MARK: - signature の引数ラベル

    /// signature 文字列がソースの引数ラベルを全部載せていない、既知の例外(理由付き)。
    /// このテストは「載せ忘れ」の検出が目的なので、**載せない判断をした項目だけ**をここに置く
    /// (ラベルが採れない・オーバーロードで集合が割れているだけの理由でここへ足さない)
    private static let labelAllowlist: [String: String] = [
        "tap": "座標形 tap(x:, y:, holdSeconds:) は別オーバーロードとして存在するが、"
            + "索引は selector 版の引数だけを signature に載せる(x/y は summary の散文で説明する。"
            + "CommandIndex.swift の tap のコメント参照)。x/y は意図的に signature から除外する",
    ]

    /// 引数リストのテキスト(丸括弧の中身)→ ラベル集合。トップレベルのカンマで区切り、
    /// 各片を `(_|外部ラベル) 内部名:` / `ラベル:` の形で読む。位置引数(`_`)は含めない
    private func argumentLabels(inParenthesizedText argsText: String) -> Set<String> {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for ch in argsText {
            switch ch {
            case "(", "[", "<":
                depth += 1
                current.append(ch)
            case ")", "]", ">":
                depth -= 1
                current.append(ch)
            case "," where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(current) }

        var labels: Set<String> = []
        for rawPart in parts {
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty, let colon = part.firstIndex(of: ":") else { continue }
            let namesPart = part[part.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let tokens = namesPart.split(separator: " ").map(String.init)
            guard let first = tokens.first else { continue }
            if tokens.count >= 2 {
                if first != "_" { labels.insert(first) }
            } else {
                labels.insert(first)
            }
        }
        return labels
    }

    /// 最初の `(` に対応する `)` までの中身(深さで対応を追う。ネストした `()`/`[]`/`<>` も安全)
    private func balancedArguments(in text: Substring) -> Substring? {
        guard let start = text.firstIndex(of: "(") else { return nil }
        var depth = 0
        var idx = start
        while idx < text.endIndex {
            if text[idx] == "(" { depth += 1 } else if text[idx] == ")" {
                depth -= 1
                if depth == 0 { return text[text.index(after: start)..<idx] }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    /// `prefix` で始まる関数宣言(複数行の引数リストも丸括弧の深さで辿る)を名前ごとに集め、
    /// 全オーバーロードの引数ラベルを合算する。`file:`/`line:` の `#filePath`/`#line` 既定引数は除く。
    /// `nameFromRemainder` は `prefix` を取り除いた残りからコマンド名を作る
    /// (ValueAssertions.swift の `func thisIs(` は prefix "func this" を引いた残り "Is" に
    /// "this" を足し戻す。既存の `names(in:prefix:anchoredToLineStart:)` と同じ規約)
    private func declaredArgumentLabels(in source: String, prefix: String, anchored: Bool,
                                        nameFromRemainder: (String) -> String = { $0 }
    ) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let searchLine = anchored ? rawLine : rawLine.trimmingCharacters(in: .whitespaces)
            guard searchLine.hasPrefix(prefix) else { i += 1; continue }

            var buffer = searchLine
            var depth = buffer.filter { $0 == "(" }.count - buffer.filter { $0 == ")" }.count
            var j = i
            while depth > 0, j + 1 < lines.count {
                j += 1
                buffer += "\n" + lines[j]
                depth += lines[j].filter { $0 == "(" }.count - lines[j].filter { $0 == ")" }.count
            }

            defer { i = j + 1 }
            guard let parenIndex = buffer.firstIndex(of: "(") else { continue }
            let remainderStart = buffer.index(buffer.startIndex, offsetBy: prefix.count)
            guard remainderStart <= parenIndex else { continue }
            let name = nameFromRemainder(String(buffer[remainderStart..<parenIndex]))
            guard !name.isEmpty, !name.contains(" ") else { continue }

            guard let argsText = balancedArguments(in: Substring(buffer)) else { continue }
            let labels = argumentLabels(inParenthesizedText: String(argsText))
                .subtracting(["file", "line"])
            result[name, default: []].formUnion(labels)
        }
        return result
    }

    /// signature 文字列(索引の表記)からラベルだけを読む。`\w+:` の出現をすべて拾う
    /// (`select(selector).xxx(timeout:)` のような chain 表記でも `selector` は無視される)
    private func declaredLabels(inSignature signature: String) -> Set<String> {
        var labels: Set<String> = []
        var current = ""
        for ch in signature {
            if ch.isLetter || ch.isNumber || ch == "_" {
                current.append(ch)
            } else {
                if ch == ":", !current.isEmpty { labels.insert(current) }
                current = ""
            }
        }
        return labels
    }

    /// 索引の signature に載っている引数ラベルの集合が、ソースの宣言と一致することを固定する。
    /// ズレると `ft_batch` が「そんな引数は無い」と実在する引数を誤って断る(scrollTo 等の
    /// startMarginRatio:/endMarginRatio: が抜けていた実害)。既知の例外は `labelAllowlist` へ
    func testSignatureLabelsMatchSource() throws {
        let commandsSource = try self.commandsSource()
        let sourceLabels = declaredArgumentLabels(in: commandsSource, prefix: "public func ",
                                                  anchored: true)
        let thisSourceLabels = declaredArgumentLabels(
            in: try source("ValueAssertions.swift"), prefix: "func this", anchored: false,
            nameFromRemainder: { "this" + $0 })

        for command in DSLCommandIndex.all {
            if Self.labelAllowlist[command.name] != nil { continue }
            let declared = sourceLabels[command.name] ?? thisSourceLabels[command.name] ?? []
            let indexed = declaredLabels(inSignature: command.signature)
            XCTAssertEqual(indexed, declared,
                          "\(command.name): 索引の signature の引数ラベルがソースとズレている"
                              + "(索引=\(indexed.sorted()) / ソース=\(declared.sorted()))")
        }
    }

    /// allowlist に載っている名前が実在すること(改名・削除の追随漏れを検出する)
    func testLabelAllowlistNamesExist() {
        let names = Set(DSLCommandIndex.all.map(\.name))
        for allowlisted in Self.labelAllowlist.keys {
            XCTAssertTrue(names.contains(allowlisted),
                          "labelAllowlist に存在しないコマンド名: \(allowlisted)")
        }
    }

}
