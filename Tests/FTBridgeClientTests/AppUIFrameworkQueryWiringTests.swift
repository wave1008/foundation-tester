// アプリの UI フレームワークを**AppUIFrameworkQuery 以外で決めていない**ことを固定する。
//
// 起動時プローブの締切は「suspend したアプリは TCP を受理して答えない」を素早く諦めるための
// 値で、**冷えた実機ブリッジがそこに収まる保証は無い**。自己申告だけで決めると締切を外した回が
// 黙って不明になり、しかも自己申告の規則(InAppBridge.uiFramework)はパッケージのマーカーより弱い
// (`SkikoUIView` を見ない)。何も失敗しないので緑は証拠にならない —— ここではソースで固定する
// (問い合わせの順序そのものは AppUIFrameworkQueryTests が見る)。

import Foundation
import XCTest
@testable import FTCore

final class AppUIFrameworkQueryWiringTests: FTBridgeClientSourceScanCase {

    private static let runnerPath = "Sources/FTScenarioRunner/ScenarioRunnerMain.swift"

    /// `uiFrameworkHint` への代入は**すべて**問い合わせの口を通ること
    func testEveryUIFrameworkHintAssignmentGoesThroughTheQuery() throws {
        let source = try Self.readSource(Self.runnerPath)
        let statements = Self.statements(in: source, startingWith: "uiFrameworkHint = ")
        XCTAssertGreaterThanOrEqual(statements.count, 2,
                                    "走査対象が見つからない = 変数名か書式が変わった(\(statements.count) 箇所)")
        let offenders = statements.filter { !$0.contains("AppUIFrameworkQuery.") }
        XCTAssertTrue(offenders.isEmpty,
                      "uiFramework を AppUIFrameworkQuery を通さずに決めている: \(offenders)")
    }

    /// ブリッジの自己申告(`StatusResponse.uiFramework`)を読むのは AppUIFrameworkQuery だけ。
    /// 直接読むと、注入先が別アプリの申告や弱い規則の申告で静的な答えを上書きする経路が生える
    func testOnlyTheQueryReadsTheBridgeSelfReport() throws {
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100, "走査が Sources に届いていない")
        let read = try NSRegularExpression(pattern: #"(tatus|\))\??\.uiFramework\b"#)
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "AppUIFrameworkQuery.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in read.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let index = Range(match.range, in: text)!.lowerBound
                offenders.append("\(file.lastPathComponent):\(Self.lineNumber(of: index, in: text))")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "自己申告は AppUIFrameworkQuery.bridgeReport(_:about:) を通して読む: \(offenders)")
    }
}

extension FTBridgeClientSourceScanCase {
    /// `prefix`(比較 `==` と取り違えないよう末尾の空白まで含める)で始まる**文**(継続行を含む)を取り出す。継続の判定は
    /// 「カッコが閉じていない」か「行末が演算子/カンマ」か「次の行が `??` で始まる」
    static func statements(in source: String, startingWith prefix: String) -> [String] {
        var result: [String] = []
        let lines = source.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            defer { index += 1 }
            guard lines[index].contains(prefix) else { continue }
            var text = lines[index]
            var next = index + 1
            while next < lines.count {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let opens = text.filter { $0 == "(" }.count
                let closes = text.filter { $0 == ")" }.count
                let continues = opens > closes || trimmed.hasSuffix("??") || trimmed.hasSuffix(",")
                    || lines[next].trimmingCharacters(in: .whitespaces).hasPrefix("??")
                guard continues else { break }
                text += " " + lines[next]
                next += 1
            }
            result.append(Self.collapsed(text))
        }
        return result
    }
}
