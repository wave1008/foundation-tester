// 極性の割れる語を書かない規則(CLAUDE.md §用語(陽性/陰性)・VocabularyPolarityTests)の英語版。
// false positive / false negative は検知として語るか判定として語るかで極性が反転する語で、テキストの可視性検証の失敗文言が
// `false positive (occlusion)` だった(今は `text visibility check failed (offscreen | on screen…)`)。
// 走査するのは利用者に届く面だけ: CLI・ブリッジ・拡張のソース、user-docs、スキル。保守者の docs は経緯の記録に旧文言を残す。

import Foundation
import XCTest
import FTCore
import FTTestSupport

final class FailureWordingVocabularyTests: XCTestCase {

    private static let banned = #"false[ -]?(positive|negative)"#

    private static let scannedPrefixes = [
        "Sources/", "InAppBridge/", "Runner/", "AndroidRunner/", "vscode-fleetest/src/",
        "docs/user-docs/", ".claude/skills/",
    ]

    private static let scannedExtensions: Set<String> = ["swift", "md", "ts", "js", "mjs", "kt", "java", "m", "h", "json"]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func scan() throws -> (hits: [String], scanned: Set<String>) {
        let root = repoRoot
        let regex = try NSRegularExpression(pattern: banned, options: [.caseInsensitive])
        var hits: [String] = []
        var scanned: Set<String> = []
        for relative in try GitListedFiles.list(in: root)
        where scannedPrefixes.contains(where: { relative.hasPrefix($0) })
            && scannedExtensions.contains((relative as NSString).pathExtension) {
            guard let text = try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            else { continue }
            scanned.insert(relative)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(line)
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    hits.append("\(relative):\(index + 1): " + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return (hits, scanned)
    }

    func testFalsePositiveWordingIsGone() throws {
        XCTAssertEqual(try Self.scan().hits, [],
                       "テキストの可視性検証は `text visibility check failed (…)`。極性の割れる false positive / negative は書かない")
    }

    /// 走査が失敗文言の実体と user-docs へ届いていること
    func testScanReachesTheFailureWording() throws {
        let scanned = try Self.scan().scanned
        for path in ["Sources/FTCore/StepExecutor+Assert.swift",
                     "docs/user-docs/reference/testclass/text_visibility_check.md"] {
            XCTAssertTrue(scanned.contains(path), "走査が届いていない: \(path)")
        }
    }
}
