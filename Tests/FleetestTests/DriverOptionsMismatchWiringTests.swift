// `@OptionGroup var driverOptions: DriverOptions` を持つコマンドは、自分の validate() から
// `rejectDeviceTargetMismatch` を呼ぶこと(呼び忘れ検出)。ArgumentParser は OptionGroup の
// validate() を自動では呼ばない(swift-argument-parser 1.8.2: CommandParser.descendingParse は
// 各コマンドノードの validate() を1回呼ぶだけで、ネストした ParsableArguments 側へは降りない。
// 既定実装は空 `{}`)—— 呼び忘れは黙って通る。判定は Sources/fleetest のソース走査で行う
// (実行時に driverOptions を持つ型を列挙する手段が無いため)。

import Foundation
import XCTest

final class DriverOptionsMismatchWiringTests: XCTestCase {

    /// 呼ばなくてよい理由がある型名。**ここに載っている型だけ**が検査を免除される —— 新しく
    /// driverOptions を足した型は自動では載らないので、呼び忘れはここへ来ず落ちる
    private static let exempt: Set<String> = []

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Sources/fleetest")
    }

    private struct CommandType {
        let name: String
        let file: String
        /// 自分の直接の本体テキスト(ネストした AsyncParsableCommand の本体は除いた「自分だけ」の分)
        let ownBody: String
    }

    /// 文字列リテラル・コメントの中の `{`/`}` を無効化する(brace の対応数えを壊さないため)。
    /// **トリプルクォート文字列にも対応**(1ファイルだけ使用あり)。配列の長さ・添字は元の
    /// テキストと1:1のまま(無効化は文字の置換だけ)なので、見つけた範囲をそのまま元テキストから切り出せる
    private static func maskStringsAndComments(_ source: String) -> [Character] {
        var chars = Array(source)
        let n = chars.count
        enum State { case normal, lineComment, blockComment, string, tripleString }
        var state = State.normal
        var i = 0
        func neutralize(_ idx: Int) {
            if chars[idx] == "{" || chars[idx] == "}" { chars[idx] = "x" }
        }
        while i < n {
            switch state {
            case .normal:
                if i + 2 < n, chars[i] == "\"", chars[i + 1] == "\"", chars[i + 2] == "\"" {
                    state = .tripleString; i += 3; continue
                }
                if chars[i] == "\"" { state = .string; i += 1; continue }
                if i + 1 < n, chars[i] == "/", chars[i + 1] == "/" { state = .lineComment; i += 2; continue }
                if i + 1 < n, chars[i] == "/", chars[i + 1] == "*" { state = .blockComment; i += 2; continue }
                i += 1
            case .lineComment:
                if chars[i] == "\n" { state = .normal; i += 1; continue }
                neutralize(i); i += 1
            case .blockComment:
                if i + 1 < n, chars[i] == "*", chars[i + 1] == "/" {
                    neutralize(i); neutralize(i + 1); state = .normal; i += 2; continue
                }
                neutralize(i); i += 1
            case .string:
                if chars[i] == "\\", i + 1 < n { neutralize(i); neutralize(i + 1); i += 2; continue }
                if chars[i] == "\"" { state = .normal; i += 1; continue }
                neutralize(i); i += 1
            case .tripleString:
                if i + 2 < n, chars[i] == "\"", chars[i + 1] == "\"", chars[i + 2] == "\"" {
                    state = .normal; i += 3; continue
                }
                neutralize(i); i += 1
            }
        }
        return chars
    }

    /// `struct NAME: AsyncParsableCommand {` を全部見つけ、対応する `}` までの範囲(brace を含まない
    /// 中身)を1つずつ返す。ネストした一致(`Bridge` の中の `Up`/`Down`/`Status` 等)も別々に見つかる
    private static func commandTypeRanges(masked: [Character]) -> [(name: String, range: Range<Int>)] {
        let maskedString = String(masked)
        let ns = maskedString as NSString
        let pattern = try! NSRegularExpression(pattern: "struct (\\w+)\\s*:\\s*AsyncParsableCommand\\s*\\{")
        var results: [(String, Range<Int>)] = []
        for match in pattern.matches(in: maskedString, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            let openBrace = match.range.location + match.range.length - 1
            var depth = 1
            var idx = openBrace + 1
            while idx < masked.count, depth > 0 {
                if masked[idx] == "{" { depth += 1 } else if masked[idx] == "}" { depth -= 1 }
                idx += 1
            }
            guard depth == 0 else { continue }  // 対応する閉じ括弧が見つからない(走査バグ)は無視
            results.append((name, (openBrace + 1)..<(idx - 1)))
        }
        return results
    }

    /// 各型の「自分だけ」の本体を返す(ネストした AsyncParsableCommand 型の本体を空白へ差し替えた版)。
    /// これが無いと `Bridge`(driverOptions を自分では持たない入れ物)が、中の `Up`/`Status` の
    /// テキストを間接的に含んでしまい、判定が型ごとに正しく閉じない
    private static func extractOwnBodies(source: String, file: String) -> [CommandType] {
        let masked = maskStringsAndComments(source)
        let ranges = commandTypeRanges(masked: masked)
        let sourceChars = Array(source)
        return ranges.map { entry in
            var body = Array(sourceChars[entry.range])
            let localBase = entry.range.lowerBound
            for other in ranges where other.range != entry.range
                && entry.range.contains(other.range.lowerBound)
                && entry.range.contains(other.range.upperBound - 1) {
                for idx in other.range { body[idx - localBase] = " " }
            }
            return CommandType(name: entry.name, file: file, ownBody: String(body))
        }
    }

    func testDriverOptionsCommandsCallRejectDeviceTargetMismatch() throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: Self.sourcesRoot, includingPropertiesForKeys: nil) else {
            return XCTFail("cannot enumerate \(Self.sourcesRoot.path)")
        }
        var violations: [String] = []
        var driverOptionsTypeCount = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for command in Self.extractOwnBodies(source: text, file: url.lastPathComponent) {
                guard command.ownBody.contains("@OptionGroup var driverOptions: DriverOptions") else { continue }
                driverOptionsTypeCount += 1
                guard !Self.exempt.contains(command.name) else { continue }
                if !command.ownBody.contains("rejectDeviceTargetMismatch(") {
                    violations.append("\(command.file): \(command.name)")
                }
            }
        }
        // 走査そのものが壊れて空集合を舐めているだけ、という緑を防ぐ(CommentDateScanTests と同じ規律)。
        // 現在の実数は14(ApiListApps・ApiLiveServe・Bridge.Up・Bridge.Status・ManualDriveCommands の9個・
        // VisionCapture)。ここでは新規追加で増える分だけ緩め、機械的に減った(=走査が壊れた)ことだけを検出する
        XCTAssertGreaterThanOrEqual(driverOptionsTypeCount, 14, "scan found fewer driverOptions-holding"
            + " commands than expected — the scan itself may be broken")
        XCTAssertTrue(violations.isEmpty, """
            these commands hold DriverOptions but their validate() never calls \
            rejectDeviceTargetMismatch() (add the call, or add the type name to \
            DriverOptionsMismatchWiringTests.exempt with a reason):
            \(violations.joined(separator: "\n"))
            """)
    }

    // MARK: - スキャナ自体のテスト(デバイス不要)

    func testMaskingNeutralizesBracesInStringsAndComments() {
        let source = #"""
        struct A: AsyncParsableCommand {
            let s = "{ not a brace }"
            // { also not a brace }
            /* { nor this } */
            func run() { print("ok") }
        }
        """#
        let masked = Self.maskStringsAndComments(source)
        let bodies = Self.commandTypeRanges(masked: masked)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies.first?.name, "A")
    }

    func testNestedCommandBodyIsExcludedFromOuterOwnBody() {
        let source = """
        struct Outer: AsyncParsableCommand {
            struct Inner: AsyncParsableCommand {
                @OptionGroup var driverOptions: DriverOptions
                func validate() throws { try driverOptions.rejectDeviceTargetMismatch() }
            }
        }
        """
        let commands = Self.extractOwnBodies(source: source, file: "x.swift")
        let outer = commands.first { $0.name == "Outer" }
        let inner = commands.first { $0.name == "Inner" }
        XCTAssertFalse(outer?.ownBody.contains("driverOptions") ?? true,
                       "Outer's own body must not see Inner's driverOptions line")
        XCTAssertTrue(inner?.ownBody.contains("rejectDeviceTargetMismatch(") ?? false)
    }
}
