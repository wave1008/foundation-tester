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
}
