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

}
