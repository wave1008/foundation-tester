// physicalUDID の配線漏れを防ぐソース走査。
//
// `BridgeClient` は physicalUDID を持つときだけ実機として振る舞う(installTarget()/
// simctlTarget()/simulatorTarget() の分岐)。**実機の CLI 引数(--physical/--udid)や
// プロファイルの device.physical が既にスコープに来ている構築箇所**でこれを渡し忘れると、
// 名前引きの simctl 経路へ誤って落ち、実機なのに「Invalid device: <名前>」という的外れな
// 失敗になる(2026-08-09 実測。ScenarioRunnerMain.swift の3箇所で実際に踏んだ)。
//
// 対象は「実機かどうかの情報を既に持っている」ファイルだけに絞る(MCP のポート直指定や
// --port 単体の CLI コマンドは physicalUDID を元々持たず、BridgeClient 内部の名前引き
// フォールバックに委ねる設計 —— そちらまで対象にすると意図的な設計を誤検知する)。
final class PhysicalUDIDPlumbingTests: FTBridgeClientSourceScanCase {

    /// 実機かどうかの情報(--physical/--udid・device.physical)が既にスコープに来ている
    /// ファイル。ここでの `BridgeClient(port: ...)` 構築は必ず physicalUDID を渡すこと
    private static let filesRequiringPhysicalUDID = [
        "Sources/FTScenarioRunner/ScenarioRunnerMain.swift",
        "Sources/FTAndroid/ProfileWorkerFactory.swift",
    ]

    func testEveryBridgeClientConstructionForwardsPhysicalUDID() throws {
        var checked = 0
        var offenders: [String] = []
        for relativePath in Self.filesRequiringPhysicalUDID {
            let source = try Self.readSource(relativePath)
            for range in Self.argumentRanges(in: source, callPrefix: "BridgeClient(port:") {
                checked += 1
                if !source[range].contains("physicalUDID") {
                    offenders.append("\(relativePath):\(Self.lineNumber(of: range.lowerBound, in: source))")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "走査対象が見つからない = パスかシグネチャの書式が変わった")
        XCTAssertTrue(offenders.isEmpty,
                      "BridgeClient(port: ...) の構築は physicalUDID: を渡すこと(渡さないと実機で"
                      + " 名前引きの simctl 経路へ誤って落ち、Invalid device の的外れな失敗になる): \(offenders)")
    }
}

// MARK: - 共通ヘルパー(ソース走査系テストで使い回す)

import XCTest

class FTBridgeClientSourceScanCase: XCTestCase {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FTBridgeClientTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // リポジトリルート

    static func readSource(_ relativePath: String) throws -> String {
        let file = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    static func lineNumber(of index: String.Index, in source: String) -> Int {
        source[source.startIndex..<index].filter { $0 == "\n" }.count + 1
    }

    /// `callPrefix`(例 "BridgeClient(port:")で始まる呼び出しの引数リスト全体を返す。
    /// 丸カッコの対応を数えて取り出すため、複数行の呼び出しにもまたがる
    static func argumentRanges(in source: String, callPrefix: String) -> [Range<String.Index>] {
        precondition(callPrefix.hasSuffix(":") && callPrefix.contains("("))
        let callee = String(callPrefix[callPrefix.startIndex..<callPrefix.firstIndex(of: "(")!])
        var ranges: [Range<String.Index>] = []
        var searchStart = source.startIndex
        while let hit = source.range(of: callPrefix, range: searchStart..<source.endIndex) {
            let openParen = source.index(hit.lowerBound, offsetBy: callee.count)
            var depth = 0
            var index = openParen
            var closeParen: String.Index?
            while index < source.endIndex {
                let ch = source[index]
                if ch == "(" { depth += 1 } else if ch == ")" {
                    depth -= 1
                    if depth == 0 { closeParen = index; break }
                }
                index = source.index(after: index)
            }
            guard let close = closeParen else { break }
            ranges.append(source.index(after: openParen)..<close)
            searchStart = source.index(after: close)
        }
        return ranges
    }
}
