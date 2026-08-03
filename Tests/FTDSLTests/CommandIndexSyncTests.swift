import XCTest
@testable import FTDSL

/// `ftester api dsl-commands` が出す索引(Sources/FTDSL/CommandIndex.swift)を**ソースと突き合わせる**。
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

    /// 行頭 `public func 名前(` を拾う(トップレベルの自由関数だけ = 索引の対象)
    private func topLevelFunctions(in source: String) -> Set<String> {
        names(in: source, prefix: "public func ", anchoredToLineStart: true)
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
        let commands = topLevelFunctions(in: try source("Commands.swift"))
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
        let commandsSource = try source("Commands.swift")
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

    /// 改名した旧コマンド名は UnavailableCommands.swift に unavailable スタブが要る
    /// (無いと `cannot find 'X' in scope` としか出ず、書き手は新名を知らないまま当てずっぽうを試す)。
    /// `@available(*, unavailable...)` はコンパイル時にしか効かないので実行時テストにできない。
    /// ここではソース走査で「スタブが実在し、正しい新名を案内している」ことだけ確かめる
    func testRenamedCommandsHaveUnavailableStubs() throws {
        let renames: [(old: String, new: String)] = [
            ("isEnabled", "enabledIsTrue"),
            ("isDisabled", "enabledIsFalse"),
            ("isChecked", "checkIsON"),
            ("isNotChecked", "checkIsOFF"),
        ]
        let unavailable = try source("UnavailableCommands.swift")
        for (old, new) in renames {
            XCTAssertTrue(unavailable.contains("public func \(old)("),
                          "\(old) の unavailable スタブが無い(改名の追随漏れ)")
            XCTAssertTrue(unavailable.contains(new),
                          "\(old) のスタブが新名 \(new) を案内していない")
        }
    }
}
