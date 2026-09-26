// FM が判定を返さないとき(macOS 26 / 実呼び出しの失敗 / 陽性対照の注入)に occlusionFlip が
// OCROnlyVisibility へ落ちる配線の固定。振る舞いテスト(StepExecutorTests+OCROnlyVisibility.swift)は
// インク経由の notVisible/undetermined しか実際には駆動できない(lines 経由の visible は Vision の
// 実読みが要るため確定的に再現できない) —— `.visible` 分岐が `visibilityGuardSkipped` を立てない
// ことと `.notVisible`/`.undetermined` の countsAsSkipped の配線は、この2点だけソース走査で固定する。

import XCTest
@testable import FTCore

final class OCROnlyVisibilityWiringTests: XCTestCase {
    private var source: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/StepExecutor+Assert.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func body(from startMarker: String, to endMarker: String, in text: String) throws -> String {
        guard let start = text.range(of: startMarker),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex)
        else { throw XCTSkip("マーカーが見つからない(書式が変わった): \(startMarker)") }
        return String(text[start.lowerBound..<end.lowerBound])
    }

    /// macOS 26・陽性対照の注入で FM を撃たない配線: delegate の nil チェックだけが早期 return で、
    /// FMVisionSupport はここでは見ない(下流の fmAvailable でだけ効く)
    func testDelegateGateNoLongerChecksFMVisionSupport() throws {
        let text = source
        XCTAssertFalse(text.isEmpty, "走査対象が読めていない")
        XCTAssertTrue(text.contains("guard let delegate else { return nil }"),
                      "delegate の nil チェックは FMVisionSupport と切り離されているはず")
        XCTAssertTrue(text.contains(
            "let fmAvailable = FMVisionSupport.isSupported && !FMNoVerdictInjection.isActive()"),
            "FM を撃てるかは fmAvailable の1箇所で決めるはず")
        XCTAssertTrue(text.contains("if fmAvailable { delegate.prewarmVisibilityCheck() }"),
                      "暖機も fmAvailable でだけ撃つはず")
    }

    /// fmAvailable が false のとき FM を呼ばず OCROnlyVisibility へ落ち、
    /// FM に訊いていないので countsAsSkipped: false
    func testUnavailableFMFallsBackWithoutCountingAsSkipped() throws {
        let block = try body(from: "guard fmAvailable else {",
                             to: "let memoKey = VisibilityVerdictMemo.key(", in: source)
        XCTAssertTrue(block.contains("applyOCROnlyVisibility("), block)
        XCTAssertTrue(block.contains("countsAsSkipped: false"), block)
    }

    /// FM に実際に訊いたのに答えが無かったときは countsAsSkipped: true
    /// (visibilityGuardSkipped を立てる側)
    func testNoVerdictFromFMCountsAsSkipped() throws {
        let block = try body(from: "guard let fresh = freshVerdict",
                             to: "visibilityVerdictMemo.store(", in: source)
        XCTAssertTrue(block.contains("applyOCROnlyVisibility("), block)
        XCTAssertTrue(block.contains("countsAsSkipped: true"), block)
    }

    /// applyOCROnlyVisibility 本体: 可視側は visibilityGuardSkipped を立てず、
    /// 不可視側は無条件に ocrOnlyWouldFlip を立ててから countsAsSkipped で分岐する
    func testApplyOCROnlyVisibilityBranchWiring() throws {
        let block = try body(from: "private func applyOCROnlyVisibility(",
                             to: "/// [occlusion-guard Tier-2 measure]", in: source)
        guard let visibleCase = block.range(of: "case .visible(let state):"),
              let notVisibleCase = block.range(of: "case .notVisible(let state):"),
              let undeterminedCase = block.range(of: "case .undetermined:")
        else { return XCTFail("switch の case が見つからない(書式が変わった)") }
        let visibleBody = String(block[visibleCase.upperBound..<notVisibleCase.lowerBound])
        let notVisibleBody = String(block[notVisibleCase.upperBound..<undeterminedCase.lowerBound])
        let undeterminedBody = String(block[undeterminedCase.upperBound...])

        XCTAssertFalse(visibleBody.contains(".visibilityGuardSkipped"),
                       "可視側は FM で見えていると確認できたので visibilityGuardSkipped を立てないはず")
        XCTAssertTrue(notVisibleBody.contains(".ocrOnlyWouldFlip"),
                      "不可視側は無条件に ocrOnlyWouldFlip を立てるはず")
        XCTAssertTrue(notVisibleBody.contains("if countsAsSkipped { noteCodesThisStep.insert(.visibilityGuardSkipped) }"))
        // 警告の段階: 不可視でも赤にしない(新しい検知は警告から。赤へ上げるのは誤検知 0 を確かめてから)
        XCTAssertTrue(notVisibleBody.contains("return nil"), "不可視側は素通り(return nil)のはず")
        // 赤にするのは検証専用の口(FT_OCR_ONLY_FLIP=1)の中だけ
        guard let gate = notVisibleBody.range(of: "if OCROnlyFlipExperiment.isActive() {"),
              let failed = notVisibleBody.range(of: ".failed(")
        else { return XCTFail("検証用の口か .failed が見つからない(書式が変わった)") }
        XCTAssertTrue(gate.upperBound <= failed.lowerBound, "検証用の口の外で赤にしている")
        XCTAssertEqual(block.components(separatedBy: ".failed(").count, 2, ".failed は1か所だけ")
        // 読んでいない(nil)を「読んで何も無かった」([])へ畳まない(畳むとインク量だけで不可視と言う)
        XCTAssertTrue(block.contains("OCROnlyVisibility.judge(lines: ocrReading?.lines,"))
        XCTAssertFalse(block.contains("ocrReading?.lines ?? []"))
        XCTAssertFalse(undeterminedBody.contains(".ocrOnlyWouldFlip"),
                       "判定不能は不可視ではないので ocrOnlyWouldFlip を立てないはず")
        XCTAssertTrue(undeterminedBody.contains("if countsAsSkipped { noteCodesThisStep.insert(.visibilityGuardSkipped) }"))
    }
}
