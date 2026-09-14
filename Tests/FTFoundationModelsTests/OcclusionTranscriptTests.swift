// occlusion の FM 段が「転写だけを求め、期待文字列を FM に渡さない」形であることの契約。
// FM そのものは単体テストで踏めないので、ここで固定できるのは①prompt / instructions に期待文字列が
// 入っていない ②出力の型が転写 1 欄 ③予算(トークン上限・拡大倍率)④等倍で読めなければ拡大して
// 読み直す ⑤両呼び出しの計上 —— の 5 つ。判定の正しさは実データで確かめてある
// (ja/en 各 80 要素 × 合成変種 + 実 run の crop 160 枚。TranscriptMatch 冒頭)。

import XCTest
@testable import FTFoundationModels

final class OcclusionTranscriptTests: XCTestCase {

    /// **期待値はリテラルで書く**(production の定数を参照すると、値を変える変異が素通りする)
    func testBudgetsArePinned() {
        XCTAssertEqual(OcclusionVerifier.transcriptResponseTokens, 120)
        XCTAssertEqual(OcclusionVerifier.enlargedRetryFactor, 2)
    }

    /// prompt は定数(補間が無い)で、instructions と合わせて "expected" という語を含まない。
    /// 期待文字列を FM に見せた瞬間におうむ返しが戻る(空白・別の文字で 20〜56% の見逃し)
    func testExpectedTextNeverReachesTheModel() throws {
        let source = try Self.verifierSource()
        XCTAssertTrue(source.contains("static let prompt = \"What text is drawn in this image?\""),
                      "prompt が定数でない(補間で期待文字列が入り得る)")
        let instructions = try XCTUnwrap(Self.declarationBody(after: "static let instructions = \"\"\"", in: source))
        XCTAssertFalse(instructions.lowercased().contains("expected"), "instructions が期待文字列に言及している")
        let transcribe = try XCTUnwrap(Self.functionBody(named: "transcribe", in: source))
        XCTAssertFalse(transcribe.contains("expectedText"), "転写の呼び出しに期待文字列が渡っている")
        XCTAssertTrue(transcribe.contains("Self.prompt"), "転写の呼び出しが共有の prompt 定数を使っていない")
    }

    /// 出力は転写 1 欄だけ。可否・分類の欄を足すと、読む前に結論を書いて転写がそれに合わせて
    /// 期待文字列を写す形に戻る(欄順を転写 → 可否に替えても直らなかった)
    func testTranscriptSchemaHasExactlyOneField() throws {
        let body = try XCTUnwrap(Self.declarationBody(of: "struct DrawnTextTranscript", in: Self.verifierSource()))
        XCTAssertEqual(body.components(separatedBy: "\n    var ").count - 1, 1, "転写型の欄が 1 つでない")
        XCTAssertTrue(body.contains("var text: String"))
        XCTAssertFalse(body.contains("visible"), "転写型に可否の欄がある")
    }

    /// 等倍で読めなかった回だけ拡大して読み直す(見えている小さな文字の誤った赤を救う)。
    /// 読めた回に 2 回目を撃たないこと・拡大は RegionText と同じ関数を使うこと
    func testRetriesEnlargedOnlyWhenNotVisible() throws {
        let body = try XCTUnwrap(Self.functionBody(named: "verifyCropped", in: Self.verifierSource()))
        XCTAssertTrue(body.contains("if !verdict.visible {"), "拡大の読み直しが「読めなかった回だけ」に絞られていない")
        XCTAssertTrue(body.contains("RegionText.enlarged(crop, by: Self.enlargedRetryFactor)"),
                      "拡大が OCR のはしごと別の実装になっている")
        XCTAssertEqual(body.components(separatedBy: "TranscriptMatch.judge(").count - 1, 2,
                       "判定が TranscriptMatch を等倍と拡大の 2 回通っていない")
        // 門は 1 回だけ取る(2 回で 2 回取ると、間に他ワーカーが割り込んで crop と判定がずれる)
        XCTAssertEqual(body.components(separatedBy: "FMGate.enter()").count - 1, 1)
    }

    /// 惜しい転写(字体の取り違え)は OCR に確かめさせるが、**OCR は素通りの根拠にしかしない**:
    /// 読めたときだけ visible へ倒し、読めなかったことで反転しない(RegionText の規律)
    func testOCRConfirmationOnlyPasses() throws {
        let body = try XCTUnwrap(Self.functionBody(named: "verifyCropped", in: Self.verifierSource()))
        XCTAssertTrue(body.contains("TranscriptMatch.isNearMiss("), "惜しい転写の OCR 確認が無い")
        XCTAssertTrue(body.contains("case .read(readable: true, let reading) = await RegionText.resolveWithinBudget("),
                      "OCR の読みが「丸ごと読めた」ときだけに絞られていない")
        XCTAssertTrue(body.contains("verdict = TranscriptMatch.Verdict(visible: true, state: .fullyVisible"),
                      "OCR で読めた回が visible へ倒れていない")
        XCTAssertFalse(body.contains("visible: false, state: .textMismatch") || body.contains("readable: false"),
                       "OCR の読めなかったことを反転の根拠にしている")
    }

    /// 転写の成功・失敗を FMHealth へ計上すること(結果 JSON の fm.calls とブレーカの根拠)
    func testTranscribeIsAccounted() throws {
        let body = try XCTUnwrap(Self.functionBody(named: "transcribe", in: Self.verifierSource()))
        XCTAssertEqual(body.components(separatedBy: "FMHealth.record(kind: \"occlusion\"").count - 1, 2,
                       "転写の FM 計上が 2 本(成功 / 失敗)ではない")
    }

    // MARK: - ソースの切り出し

    static func verifierSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTFoundationModels/OcclusionVerifier.swift"),
                   encoding: .utf8)
    }

    static func functionBody(named name: String, in source: String) -> String? {
        balancedBody(after: "func \(name)(", in: source)
    }

    static func declarationBody(of declaration: String, in source: String) -> String? {
        balancedBody(after: declaration, in: source)
    }

    /// `"""` で始まる複数行リテラルの本文
    static func declarationBody(after needle: String, in source: String) -> String? {
        guard let start = source.range(of: needle),
              let end = source.range(of: "\"\"\"", range: start.upperBound..<source.endIndex) else { return nil }
        return String(source[start.upperBound..<end.lowerBound])
    }

    private static func balancedBody(after needle: String, in source: String) -> String? {
        guard let found = source.range(of: needle),
              let open = source[found.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
