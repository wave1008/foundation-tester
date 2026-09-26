// FM が判定を返さないときの代替判定(OCROnlyVisibility)の純関数テスト。
// 追加の OCR は撃たない契約なので、ここでは Vision を一切呼ばず `lines`/`inkStdDev` を直接与える。

import XCTest
@testable import FTCore

final class OCROnlyVisibilityTests: XCTestCase {

    private let threshold = 12.0

    func testLinesMatchingExpectedAreVisible() {
        let outcome = OCROnlyVisibility.judge(lines: ["ログイン"], expected: "ログイン",
                                              inkStdDev: nil, inkThreshold: threshold)
        XCTAssertEqual(outcome, .visible(.fullyVisible))
    }

    func testLinesWithUnrelatedTextAreNotVisible() {
        let outcome = OCROnlyVisibility.judge(lines: ["ピン留め"], expected: "概要",
                                              inkStdDev: nil, inkThreshold: threshold)
        XCTAssertEqual(outcome, .notVisible(.textMismatch))
    }

    /// 読めた先頭が期待の半分以下(TranscriptMatch.mostlyHiddenRatio)は notVisible(mostlyHidden)
    func testLinesWithMostlyHiddenPrefixAreNotVisible() {
        let outcome = OCROnlyVisibility.judge(lines: ["ab"], expected: "abcdefgh",
                                              inkStdDev: nil, inkThreshold: threshold)
        XCTAssertEqual(outcome, .notVisible(.mostlyHidden))
    }

    /// 読んでいない(近道が撃たれていない)なら、低インクでも判定しない
    func testNoReadingIsUndeterminedEvenWithLowInk() {
        XCTAssertEqual(OCROnlyVisibility.judge(lines: nil, expected: "ログイン", inkStdDev: 2, inkThreshold: threshold),
                       .undetermined)
    }

    func testNoLinesWithLowInkAreNotVisible() {
        let outcome = OCROnlyVisibility.judge(lines: [], expected: "ログイン",
                                              inkStdDev: 2, inkThreshold: threshold)
        XCTAssertEqual(outcome, .notVisible(.notRendered))
    }

    func testNoLinesWithHighInkAreUndetermined() {
        let outcome = OCROnlyVisibility.judge(lines: [], expected: "ログイン",
                                              inkStdDev: 40, inkThreshold: threshold)
        XCTAssertEqual(outcome, .undetermined)
    }

    func testNoLinesWithNilInkAreUndetermined() {
        let outcome = OCROnlyVisibility.judge(lines: [], expected: "ログイン",
                                              inkStdDev: nil, inkThreshold: threshold)
        XCTAssertEqual(outcome, .undetermined)
    }

    /// 境界: ink がちょうど閾値なら「未満」ではないので判定不能側(Tier-1 と同じ「以上は疑わない」向き)
    func testInkExactlyAtThresholdIsUndetermined() {
        let outcome = OCROnlyVisibility.judge(lines: [], expected: "ログイン",
                                              inkStdDev: threshold, inkThreshold: threshold)
        XCTAssertEqual(outcome, .undetermined)
    }

    // MARK: - FMNoVerdictInjection(陽性対照の注入口)

    func testInjectionIsActiveOnlyForExactly1() {
        XCTAssertTrue(FMNoVerdictInjection.isActive(environment: ["FT_FAKE_FM_NO_VERDICT": "1"]))
        XCTAssertFalse(FMNoVerdictInjection.isActive(environment: [:]))
        XCTAssertFalse(FMNoVerdictInjection.isActive(environment: ["FT_FAKE_FM_NO_VERDICT": "true"]))
        XCTAssertFalse(FMNoVerdictInjection.isActive(environment: ["FT_FAKE_FM_NO_VERDICT": "0"]))
    }

    // MARK: - OCR と FM の突き合わせ(merge)

    /// 割れたら見えていると読めた側を採る(両方向)。注記で割れた向きを残す
    func testMergeTakesTheSideThatReadTheText() {
        let ocrRead = OCROnlyVisibility.merge(fmVisible: false, fmState: .covered,
                                              ocr: .visible(.partiallyHidden))
        XCTAssertTrue(ocrRead.visible)
        XCTAssertEqual(ocrRead.state, .partiallyHidden, "緑の注記は読めた側(OCR)の形を使う")
        XCTAssertEqual(ocrRead.disagreement, .ocrReadWhatFMMissed)

        let fmRead = OCROnlyVisibility.merge(fmVisible: true, fmState: .fullyVisible,
                                             ocr: .notVisible(.textMismatch))
        XCTAssertTrue(fmRead.visible)
        XCTAssertEqual(fmRead.state, .fullyVisible)
        XCTAssertEqual(fmRead.disagreement, .fmReadWhatOCRMissed)
    }

    /// 両方が見えないと言ったとき・OCR が判定不能のときは FM の判定のまま(割れていないので注記なし)
    func testMergeKeepsFMWhenTheyAgreeOrOCRCannotJudge() {
        let bothRed = OCROnlyVisibility.merge(fmVisible: false, fmState: .notRendered,
                                              ocr: .notVisible(.notRendered))
        XCTAssertFalse(bothRed.visible)
        XCTAssertNil(bothRed.disagreement)

        let ocrUnknownFMRed = OCROnlyVisibility.merge(fmVisible: false, fmState: .covered, ocr: .undetermined)
        XCTAssertFalse(ocrUnknownFMRed.visible, "OCR が判定不能なら FM の赤を覆さない")
        XCTAssertNil(ocrUnknownFMRed.disagreement)

        let ocrUnknownFMGreen = OCROnlyVisibility.merge(fmVisible: true, fmState: .ellipsized, ocr: .undetermined)
        XCTAssertTrue(ocrUnknownFMGreen.visible)
        XCTAssertEqual(ocrUnknownFMGreen.state, .ellipsized)
        XCTAssertNil(ocrUnknownFMGreen.disagreement)

        let bothGreen = OCROnlyVisibility.merge(fmVisible: true, fmState: .fullyVisible, ocr: .visible(.fullyVisible))
        XCTAssertTrue(bothGreen.visible)
        XCTAssertNil(bothGreen.disagreement)
    }
}
