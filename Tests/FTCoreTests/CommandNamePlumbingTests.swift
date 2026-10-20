// 「失敗したステップのコマンド名」が**必ず**結果 JSON に載ることのソース走査。
//
// 名前は `perform`/`performCustom` の `command:` で運ぶ。渡し忘れても**コンパイルは通り、
// テストも緑のまま**(欄が nil になるだけ)なので、実行では気付けない —— 落とすのはここだけ。
// 同型: BridgeContractTests(ルート表)/ SwipeForScroll のソース走査。
//
// **説明文から切り出す実装に戻さないこと**: description には group の前置(`[名前] tap …`)や
// 注記の括弧書きが付き、書式を変えた瞬間に集計が静かに壊れる。

import XCTest
@testable import FTCore

final class CommandNamePlumbingTests: XCTestCase {

    private var commandSources: [String] {
        ["Sources/FTDSL/Commands.swift", "Sources/FTDSL/CommandsVerify.swift",
         "Sources/FTDSL/CommandsAppControl.swift"]
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// コマンド定義の全呼び出しが `command:` を渡していること
    func testEveryCommandCallSitePassesItsName() throws {
        var missing: [String] = []
        for path in commandSources {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(path),
                                  encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where isCallSite(line) {
                // 引数リストは複数行に跨る。呼び出し開始から `file:` を含む行までを窓にする
                let window = lines[index..<min(lines.count, index + 12)]
                var joined = ""
                for candidate in window {
                    joined += candidate + "\n"
                    if candidate.contains("file:") { break }
                }
                if !joined.contains("command:") {
                    missing.append("\(path):\(index + 1) \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(missing, [], "command: を渡していない呼び出し(結果 JSON の command が nil になる)")
    }

    /// `perform` / `performCustom` を通らない記録(`screenshot` / `this*` / `verify` 等)と、その2つの内側の分岐
    /// (中断後・dry-run)も `command:` を渡すこと。呼び出し側の走査だけでは、受け取った名前を分岐で落とす形を
    /// 拾えない(performCustom の dry-run 分岐が落としていて、dry-run の照合が `home` / `appSwitcher` を見逃した)。
    /// ソース位置を持たない記録(`file: ""` = 場面の省略・中断の告知)はコマンドではないので対象外
    func testEveryRecordedStepCarriesItsCommandName() throws {
        let dir = repoRoot.appendingPathComponent("Sources/FTDSL")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        var missing: [String] = []
        var scanned = 0
        for name in files.sorted() {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            var searchFrom = text.startIndex
            while let range = text.range(of: "recordStep(", range: searchFrom..<text.endIndex) {
                searchFrom = range.upperBound
                let prefixStart = text.index(range.lowerBound, offsetBy: -5, limitedBy: text.startIndex)
                    ?? text.startIndex
                if text[prefixStart..<range.lowerBound].hasSuffix("func ") { continue }
                var depth = 1
                var cursor = range.upperBound
                while depth > 0, cursor < text.endIndex {
                    if text[cursor] == "(" { depth += 1 } else if text[cursor] == ")" { depth -= 1 }
                    cursor = text.index(after: cursor)
                }
                let call = text[range.lowerBound..<cursor]
                scanned += 1
                if call.contains(#"file: """#) || call.contains("command:") { continue }
                let lineNumber = text[..<range.lowerBound].filter { $0 == "\n" }.count + 1
                missing.append("\(name):\(lineNumber)")
            }
        }
        XCTAssertGreaterThan(scanned, 10, "走査が呼び出しに届いていない")
        XCTAssertEqual(missing, [], "command: を渡していない記録(結果 JSON と dry-run の照合で command が nil になる)")
    }

    /// リテラルで渡している名前が索引に実在すること(`terminate` と `terminateApp` のような取り違え)
    func testLiteralNamesExistInTheCommandIndex() throws {
        let known = Set(DSLCommandIndex.all.map(\.name))
        var unknown: [String] = []
        for path in commandSources {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(path),
                                  encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                // requireCore(command:) は「どのコマンドが呼んだか」のエラー文言用で、
                // 構造・ライフサイクル(setUp / ifElse 等)も名乗る = 索引の対象ではない
                if line.contains("requireCore(") { continue }
                guard let range = line.range(of: #"command: ""#) else { continue }
                let rest = line[range.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { continue }
                let name = String(rest[..<end])
                // 文字列補間で組む名前(scroll\(direction...))は静的には確かめられないので飛ばす
                if name.contains("\\") { continue }
                if !known.contains(name) { unknown.append("\(path): \(name)") }
            }
        }
        XCTAssertEqual(unknown, [], "索引(DSLCommandIndex)に無い名前を渡している")
    }

    private func isCallSite(_ line: String) -> Bool {
        guard line.contains("perform(step:") || line.contains("performCustom(") else { return false }
        // 定義側("func perform…")と、この経路を通さないラッパは対象外
        return !line.contains("func perform")
    }
}
