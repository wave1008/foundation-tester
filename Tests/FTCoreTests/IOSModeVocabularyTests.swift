// iOS の構成の語彙: 利用者が選ぶのは**モード**(inapp / xcuitest)、部品は**ブリッジ**(in-app / XCUITest)。
// 「エンジン」と、モード名としての hybrid は使わない(inapp モードの構成の説明語「ハイブリッド構成」は可)。
// コンパイルでは落ちないので、典型的な書き方だけを走査で落とす。無関係な engine(Flutter engine・Neural Engine 等)と、
// アプリプロファイルの `platform: "hybrid"`(iOS と Android の両方)は形が違うので当たらない。
//
// **走査の対象外**: TestProjects/ のシナリオ(.swift。ユーザー資産)・Tests/Fixtures/(実アプリの採取物)

import Foundation
import XCTest

final class IOSModeVocabularyTests: XCTestCase {

    private static let bannedPatterns = [
        #"iosInappEngine"#,
        #"workerEngines"#,
        #"engine\s*[=:]\s*\\?"?(inapp|hybrid|xcuitest)\b"#,
        #"\b(in-app|inapp|xcuitest|hybrid)\s+engines?\b"#,
        #"(in-app|inapp|xcuitest|hybrid)\s*エンジン"#,
    ]

    private static let scannedRoots = [
        "Sources", "InAppBridge", "Runner", "Tests", "docs", ".claude", "Scripts",
        "vscode-fleetest/src", "vscode-fleetest/schemas", "vscode-fleetest/test", "TestProjects",
        "CLAUDE.md", "AGENTS.md", "vscode-fleetest/README.md",
    ]

    private static let skippedDirectories: Set<String> = [
        ".git", ".build", ".fleetest", "node_modules", "dist", "out", "out-test", "Fixtures",
        "results", "reports", "DerivedData", "build", ".gradle", "Pods", "scenarios",
    ]

    private static let scannedExtensions: Set<String> = [
        "swift", "md", "ts", "mjs", "js", "sh", "py", "json", "m", "h",
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func scan() throws -> (hits: [String], scannedFiles: Int) {
        let root = repoRoot
        let regexes = try bannedPatterns.map { try NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        var hits: [String] = []
        var scannedFiles = 0
        for start in scannedRoots {
            let url = root.appendingPathComponent(start)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            var files: [URL] = isDirectory.boolValue ? [] : [url]
            if isDirectory.boolValue, let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
                for case let file as URL in walker {
                    if skippedDirectories.contains(file.lastPathComponent) { walker.skipDescendants(); continue }
                    if scannedExtensions.contains(file.pathExtension) { files.append(file) }
                }
            }
            for file in files where file.path != #filePath {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                scannedFiles += 1
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let line = String(line)
                    let range = NSRange(line.startIndex..., in: line)
                    if regexes.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                        hits.append("\(file.path.dropFirst(root.path.count + 1)):\(index + 1): "
                            + line.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
        return (hits, scannedFiles)
    }

    func testEngineVocabularyIsGone() throws {
        XCTAssertEqual(try Self.scan().hits, [], "設定は「inapp / xcuitest モード」、部品は「in-app / XCUITest ブリッジ」と書く")
    }

    /// 走査が実際にファイルへ届いていること(対象を外す変更で常に空を返す形を落とす)
    func testScanReachesTheTree() throws {
        XCTAssertGreaterThan(try Self.scan().scannedFiles, 1000, "走査がツリーに届いていない")
        let regex = try NSRegularExpression(pattern: Self.bannedPatterns[0], options: [.caseInsensitive])
        let sample = "\"iosInappEngine\": true"
        XCTAssertNotNil(regex.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)))
    }
}
