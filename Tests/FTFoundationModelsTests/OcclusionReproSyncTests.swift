// `Scripts/occlusion-repro.swift`(保存済み crop を再判定する単体ツール)が
// production の occlusion 呼び出しと同じことを撃っているかを見るソース走査。
//
// **ズレると気付けない**: このツールは「FM の誤判定が決定的か揺らぎか」を切り分けるために
// 使うので、instructions や欄が production と違っていても**それらしい出力が出てしまう**。
// 実際 production を英語化した後もツールは日本語のまま残っており、2026-09-03 まで
// 誰も気付かなかった(その間の再判定は別物を測っていた)。
//
// 比較するのは①instructions ②プロンプト本文 ③@Generable の欄と @Guide の文言 ④出力上限。
// ツールは fleetest に依存しない単体 .swift(Apple への最小再現コードも兼ねる)ので、
// 型を共有できない —— だからソースの文字列で突き合わせる。

import XCTest
@testable import FTFoundationModels

final class OcclusionReproSyncTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTFoundationModelsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    private func sources() throws -> (production: String, script: String) {
        (try String(contentsOf: Self.repoRoot
            .appendingPathComponent("Sources/FTFoundationModels/OcclusionVerifier.swift"), encoding: .utf8),
         try String(contentsOf: Self.repoRoot
            .appendingPathComponent("Scripts/occlusion-repro.swift"), encoding: .utf8))
    }

    func testInstructionsMatch() throws {
        let (production, script) = try sources()
        let p = try XCTUnwrap(Self.instructionsBlock(in: production), "production の instructions が読めない")
        let s = try XCTUnwrap(Self.instructionsBlock(in: script), "ツールの instructions が読めない")
        XCTAssertEqual(p, s, "occlusion-repro.swift の instructions が OcclusionVerifier とズレている")
    }

    func testPromptMatches() throws {
        let (production, script) = try sources()
        let p = try XCTUnwrap(Self.promptLine(in: production), "production のプロンプト本文が読めない")
        let s = try XCTUnwrap(Self.promptLine(in: script), "ツールのプロンプト本文が読めない")
        XCTAssertEqual(p, s, "occlusion-repro.swift のプロンプト本文が OcclusionVerifier とズレている")
    }

    /// 欄の集合と @Guide の文言。**スキーマ本文はプロンプトに入るので、欄が違えば別物を測る**
    /// (2欄に削った版は実データで反転を 106/147 取りこぼした。docs/performance-tuning.md §3.5.1)
    func testGeneratedFieldsAndGuidesMatch() throws {
        let (production, script) = try sources()
        for type in ["VisibilityVerdict", "VisibilityScreening"] {
            let p = try XCTUnwrap(Self.guides(of: type, in: production), "production に \(type) が無い")
            let s = try XCTUnwrap(Self.guides(of: type, in: script), "ツールに \(type) が無い")
            XCTAssertEqual(p, s, "\(type) の欄または @Guide の文言がズレている")
        }
    }

    func testResponseTokenBudgetsMatch() throws {
        let (_, script) = try sources()
        // ツールは単体 .swift で定数を共有できないため、production の値が書かれていることを見る
        XCTAssertTrue(script.contains("maximumResponseTokens: \(OcclusionVerifier.screeningResponseTokens)"),
                      "1段目の出力上限が production と違う")
        XCTAssertTrue(script.contains("maximumResponseTokens: \(OcclusionVerifier.detailResponseTokens)"),
                      "2段目の出力上限が production と違う")
    }

    // MARK: - 切り出し

    /// `let instructions = """ … """` / `let instructions = """` 相当のブロックを、
    /// 行頭の空白を落として返す(production は関数内で字下げされている)
    static func instructionsBlock(in source: String) -> String? {
        guard let start = source.range(of: "You visually verify UI tests."),
              let end = source.range(of: "\"\"\"", range: start.upperBound..<source.endIndex)
        else { return nil }
        let body = "You visually verify UI tests." + source[start.upperBound..<end.lowerBound]
        return body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func promptLine(in source: String) -> String? {
        guard let start = source.range(of: "\"Expected text (may be truncated") else { return nil }
        let rest = source[start.lowerBound...]
        // 文字列リテラルの終端まで(\" は含みうるので、行末の `"` ではなく次の生の `"` を探す)
        var result = "\""
        var index = source.index(after: start.lowerBound)
        while index < source.endIndex {
            let c = source[index]
            result.append(c)
            if c == "\"", source[source.index(before: index)] != "\\" { break }
            index = source.index(after: index)
        }
        _ = rest
        return result
    }

    /// 指定した @Generable 型の「(欄名, @Guide の文言)」を宣言順に返す
    static func guides(of type: String, in source: String) -> [String]? {
        guard let declaration = source.range(of: "struct \(type) {"),
              let close = source.range(of: "\n}", range: declaration.upperBound..<source.endIndex)
        else { return nil }
        let body = String(source[declaration.upperBound..<close.lowerBound])
        var pairs: [String] = []
        var pendingGuide: String?
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@Guide(description:") {
                pendingGuide = line
            } else if line.hasPrefix("var "), let guideText = pendingGuide {
                pairs.append("\(line) | \(guideText)")
                pendingGuide = nil
            }
        }
        return pairs.isEmpty ? nil : pairs
    }
}
