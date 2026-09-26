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

    /// FM の段(fmTextOcclusionCheck)と OCR の段は独立: どちらも無いときだけ早期 return。FM を撃てるかは
    /// fmAvailable の1箇所(設定 × macOS 27+ × 注入なし)で決める
    func testFMAndOCRStagesAreIndependentGates() throws {
        let text = source
        XCTAssertFalse(text.isEmpty, "走査対象が読めていない")
        XCTAssertTrue(text.contains("let fmConfigured = fmVisibilityCheckEnabled && delegate != nil"))
        XCTAssertTrue(text.contains("guard fmConfigured || occlusionOCRMode != .off else { return nil }"),
                      "FM が無くても OCR の段があれば guard は続くはず")
        XCTAssertFalse(text.contains("guard let delegate else { return nil }"),
                       "delegate が無いだけで guard を止めると OCR だけの検証が効かない")
        XCTAssertTrue(text.contains(
            "let fmAvailable = fmConfigured && FMVisionSupport.isSupported && !FMNoVerdictInjection.isActive()"))
        XCTAssertTrue(text.contains("if fmAvailable { delegate?.prewarmVisibilityCheck() }"),
                      "暖機も fmAvailable でだけ撃つはず")
    }

    /// FM の段を使わない / 使えないとき FM を呼ばず OCROnlyVisibility へ落ち、FM に訊いていないので
    /// countsAsSkipped: false。文言の「FM gave no verdict」は FM を使う設定のときだけ(fmConfigured)
    func testUnavailableFMFallsBackWithoutCountingAsSkipped() throws {
        let block = try body(from: "guard fmAvailable, let delegate else {",
                             to: "let memoKey = VisibilityVerdictMemo.key(", in: source)
        XCTAssertTrue(block.contains("applyOCROnlyVisibility("), block)
        XCTAssertTrue(block.contains("countsAsSkipped: false"), block)
        XCTAssertTrue(block.contains("fmGaveNoVerdict: fmConfigured"), block)
    }

    /// **FM の段が使えるときは OCR の赤でも FM に回す**(ユーザー決定)。OCR の結果で FM より前に
    /// 返る分岐を置かない。FM の判定の後で merge に通す(on のときだけ。measure は FM の判定を採取する)
    func testOCRRedStillGoesToFMAndIsMergedAfter() throws {
        let text = source
        let block = try body(from: "let ocrOnly = ocrOnlyOutcome(",
                             to: "guard fmAvailable, let delegate else {", in: text)
        XCTAssertFalse(block.contains("return "), "OCR の判定で FM より前に返っている: \(block)")
        XCTAssertTrue(text.contains("ocr: occlusionOCRMode == .on ? ocrOnly.outcome : .undetermined)"))
        guard let fmCall = text.range(of: "delegate.verifyElementVisible("),
              let merge = text.range(of: "OCROnlyVisibility.merge(")
        else { return XCTFail("マーカーが見つからない") }
        XCTAssertLessThan(fmCall.lowerBound, merge.lowerBound, "突き合わせは FM の判定の後")
        XCTAssertTrue(text.contains("if let note = merged.disagreement { noteCodesThisStep.insert(note) }"))
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
    /// 不可視側は FM の反転と同じく赤(launch 直後の門も消費する)
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
        XCTAssertTrue(notVisibleBody.contains("consumeFirstFrameGate(visible: false"),
                      "launch 直後の門を消費しないと launch storyboard を覆いと読んで赤にする")
        XCTAssertTrue(notVisibleBody.contains("if countsAsSkipped { noteCodesThisStep.insert(.visibilityGuardSkipped) }"))
        // 警告の段階: 不可視でも赤にしない(新しい検知は警告から。赤へ上げるのは誤検知 0 を確かめてから)
        XCTAssertTrue(notVisibleBody.contains("return .failed("), "不可視側は赤のはず")
        XCTAssertFalse(notVisibleBody.contains("return nil"), "不可視側が素通りしている")
        XCTAssertEqual(block.components(separatedBy: ".failed(").count, 2, ".failed は1か所だけ")
        // 読んでいない(nil)を「読んで何も無かった」([])へ畳まない(畳むとインク量だけで不可視と言う)
        XCTAssertTrue(block.contains("OCROnlyVisibility.judge(lines: ocrReading?.lines,"))
        XCTAssertFalse(block.contains("ocrReading?.lines ?? []"))
        XCTAssertFalse(undeterminedBody.contains(".failed("), "判定不能は赤にしない")
        XCTAssertTrue(undeterminedBody.contains("if countsAsSkipped { noteCodesThisStep.insert(.visibilityGuardSkipped) }"))
    }
}
