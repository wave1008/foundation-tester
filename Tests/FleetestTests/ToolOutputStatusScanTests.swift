// 契約: 外部コマンドの出力から値を作るときは終了コードを見る。`Shell.run` / `Shell.runData` は
// **非ゼロで投げない**ので、`output` を素で解析すると失敗の出力(空・エラー文)から確定値ができる ——
// `adb devices` の失敗が「接続中は無い」になり、停止の確認・データ削除・MCP の接続断の判定が誤った
// (負荷テスト 2026-09-27 §56.7 と同じ型の掃討)。`Shell.Result.outputIfSucceeded` か `status` を見ること。
//
// **集合は Sources/ 全体から機械的に導出する**(SharedResourceOwnershipParityTests と同じ流儀)。
// 関数単位なので、同じ関数に status を見る呼び出しが1つでもあれば他の素の読みは見逃す(粒度の限界)。
// 免除は理由つきの Set で等号固定する。

import Foundation
import XCTest

final class ToolOutputStatusScanTests: XCTestCase {

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func allSwiftFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            XCTFail("Sources/ が読めていない — テストを見直すこと")
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// **コメントを落としてから走査する** —— 規約の説明に `.output` や `status` が出るので、素のままだと
    /// 配線を消してもコメントだけで通る
    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") { return "" }
                if let range = line.range(of: " //") { return line[..<range.lowerBound] }
                return line
            }
            .joined(separator: "\n")
    }

    private func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private struct FunctionBody {
        let name: String
        let text: String
    }

    /// `func` 単位へ大まかに分割する(SharedResourceOwnershipParityTests と同じ簡易パーサ)
    private func functions(in source: String, file: String) -> [FunctionBody] {
        var results: [FunctionBody] = []
        let pattern = try! NSRegularExpression(pattern: #"func\s+(\w+)\s*[\(<]"#)
        for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let matchRange = Range(match.range, in: source),
                  let nameRange = Range(match.range(at: 1), in: source),
                  let braceStart = source.range(of: "{", range: matchRange.upperBound..<source.endIndex)
            else { continue }
            var depth = 0
            var idx = braceStart.lowerBound
            var end = source.endIndex
            while idx < source.endIndex {
                if source[idx] == "{" { depth += 1 }
                if source[idx] == "}" {
                    depth -= 1
                    if depth == 0 { end = source.index(after: idx); break }
                }
                idx = source.index(after: idx)
            }
            results.append(FunctionBody(name: "\(file).\(source[nameRange])",
                                        text: String(source[braceStart.lowerBound..<end])))
        }
        return results
    }

    private static let shellCall = #"Shell\.run(Data)?\s*\("#
    /// 素の出力の読み(`outputIfSucceeded` は語が続くので当たらない・`.data(` はメソッド呼び出しなので外す)
    private static let rawOutputRead = #"\.(output|data)\b(?!\s*\()"#
    private static let statusCheck = #"\.status\b|\bstatus\s*[!=]=|\(status,|\bstatus:"#

    /// 免除(理由つき)。**足すときは、なぜ非ゼロの出力を読んでよいかを書くこと**
    private static let exemptions: Set<String> = [
        // lsof は並べたソケットのうち1つでも開いているプロセスが無いと exit 1 を返す = 部分的な結果が
        // 正常。解析側(socketPath)は対応づけられなければ nil に倒す
        "SafariWebInspector.resolveSocketPath",
        // コマンドが `|| true` で終わる(status は常に 0)。出力は表示だけで判断に使わない
        "RemoteCommands.printDiskByIssuer",
        // WebView 更新(AndroidWebViewUpdate)へ渡す adb クロージャ。install の失敗文言
        // (exit 1・"Failure [...]")がそのまま利用者への理由になるので出力を捨てられない。
        // pull の失敗は次の install の失敗として表に出る(黙った成功にはならない)
        "ProfileRunner.run",
    ]

    /// **戻すと落ちる根拠**: `Shell.run(...).output` を status を見ずに解析する関数を足すと、
    /// 失敗の出力から「無い」「止まった」「出ていない」が確定する
    func testToolOutputIsReadOnlyAfterCheckingTheExitStatus() {
        var scanned = 0
        var violations: [String] = []
        var exemptionsSeen: Set<String> = []
        for url in allSwiftFiles() {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let source = codeOnly(raw)
            guard matches(Self.shellCall, source) else { continue }
            let file = url.deletingPathExtension().lastPathComponent
            for function in functions(in: source, file: file) where matches(Self.shellCall, function.text) {
                scanned += 1
                guard matches(Self.rawOutputRead, function.text),
                      !matches(Self.statusCheck, function.text) else { continue }
                if Self.exemptions.contains(function.name) {
                    exemptionsSeen.insert(function.name)
                } else {
                    violations.append(function.name)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "Shell.run を呼ぶ関数をほとんど見つけていない — 走査が壊れている")
        XCTAssertEqual(violations.sorted(), [], """
            終了コードを見ずに外部コマンドの出力を解析している。`Shell.Result.outputIfSucceeded` か \
            `status` を見ること(非ゼロの出力を読む理由があるなら exemptions へ理由つきで足す)
            """)
        XCTAssertEqual(exemptionsSeen, Self.exemptions,
                       "免除が当たらなくなった(直したなら免除から外す = 古い免除が新しい素の読みを隠さないように)")
    }
}
