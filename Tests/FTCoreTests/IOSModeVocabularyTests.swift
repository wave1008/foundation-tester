// iOS の構成の語彙: 利用者が選ぶのは**モード**(inapp / xcuitest)、部品は**ブリッジ**(in-app / XCUITest)。
// 部品は「in-app ブリッジ」(ハイフン付き)。「inapp」はモードの値にだけ使う。
// 「エンジン」と、モード名としての hybrid は使わない(inapp モードの構成の説明語「ハイブリッド構成」は可)。
// コンパイルでは落ちないので、典型的な書き方だけを走査で落とす。無関係な engine(Flutter engine・Neural Engine 等)と、
// アプリプロファイルの `platform: "hybrid"`(iOS と Android の両方)は形が違うので当たらない。
//
// **走査は git が管理するファイル全部**(`git ls-files` の追跡分 + 無視されていない未追跡分。シナリオ・SUT も含む)。
// ディスクを歩かない: gitignore のファイル(ビルド出力・.claude/settings.local.json・.vscode/・Flutter の生成コード)は
// クローンごとに中身が違い、そこに旧表記があると**その機械でだけ赤になりコミットでは直せない**。
// 追跡物から外すのは2つだけ: third_party/(外部コード)と Tests/Fixtures/ の .json(実アプリの画面の採取物 =
// 書き換えると採取物を偽り SweepHarnessTests の基準値もずれる。README は人が書くので対象)

import Foundation
import XCTest
import FTCore
import FTTestSupport

final class IOSModeVocabularyTests: XCTestCase {

    private static let bannedPatterns = [
        #"iosInappEngine"#,
        #"workerEngines"#,
        #"engine\s*[=:]\s*\\?"?(inapp|hybrid|xcuitest)\b"#,
        #"\b(in-app|inapp|xcuitest|hybrid)\s+engines?\b"#,
        #"(in-app|inapp|xcuitest|hybrid)\s*エンジン"#,
        // 大文字小文字を区別する(InAppBridge/・inappBridges 等の識別子に当てない)
        #"(?-i)\binapp[ \t]+(ブリッジ|bridges?\b)"#,
        #"\biOS-hybrid\b"#,
    ]

    private static func isExcluded(_ relative: String) -> Bool {
        relative.hasPrefix("third_party/")
            || (relative.hasPrefix("Tests/Fixtures/") && relative.hasSuffix(".json"))
    }

    private static let scannedExtensions: Set<String> = [
        "swift", "md", "ts", "tsx", "mjs", "js", "jsx", "sh", "py", "json", "m", "h",
        "kt", "kts", "java", "dart",
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func scan() throws -> (hits: [String], scannedPaths: Set<String>) {
        let root = repoRoot
        let regexes = try bannedPatterns.map { try NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        let selfPath = String(#filePath.dropFirst(root.path.count + 1))
        var hits: [String] = []
        var scannedPaths: Set<String> = []
        for relative in try GitListedFiles.list(in: root) where relative != selfPath && !isExcluded(relative) {
            let file = root.appendingPathComponent(relative)
            // 追跡中でも作業ツリーで消したファイルは読めない = 飛ばす
            guard scannedExtensions.contains(file.pathExtension),
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            scannedPaths.insert(relative)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(line)
                let range = NSRange(line.startIndex..., in: line)
                if regexes.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                    hits.append("\(relative):\(index + 1): " + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return (hits, scannedPaths)
    }

    func testEngineVocabularyIsGone() throws {
        XCTAssertEqual(try Self.scan().hits, [], "設定は「inapp / xcuitest モード」、部品は「in-app / XCUITest ブリッジ」と書く")
    }

    /// 走査が実際にファイルへ届いていること(対象を外す変更で常に空を返す形を落とす)
    func testScanReachesTheTree() throws {
        let scanned = try Self.scan().scannedPaths
        XCTAssertGreaterThan(scanned.count, 1000, "走査がツリーに届いていない")
        // 全体が対象: シナリオ・実アプリの採取物・SUT の Kotlin まで届いていること
        for path in ["TestProjects/E2E-CMP/scenarios/04_ジェスチャ.swift", "Tests/Fixtures/RealAppSnapshots/README.md",
                     "E2EAppCMP/composeApp/src/commonMain/kotlin/com/ftester/e2e/screens/GestureScreen.kt"] {
            XCTAssertTrue(scanned.contains(path), "走査が届いていない: \(path)")
        }
        // 外すのは third_party/ と Fixtures の採取 JSON だけ
        XCTAssertFalse(scanned.contains { $0.hasPrefix("third_party/") })
        XCTAssertFalse(scanned.contains { $0.hasPrefix("Tests/Fixtures/") && $0.hasSuffix(".json") })
        let regex = try NSRegularExpression(pattern: Self.bannedPatterns[0], options: [.caseInsensitive])
        let sample = "\"iosInappEngine\": true"
        XCTAssertNotNil(regex.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)))
    }
}
