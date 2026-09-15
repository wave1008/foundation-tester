// OCR の近道を見送った回に理由の注記(ocr-shortcut-not-warm / ocr-shortcut-busy)が残ること。
// RegionText.isWarm / abandonedInFlight はプロセス全体の状態で差し替え口が無いので、配線は
// ソース走査で固定する(見送りの分岐が両方の注記を持ち、OCR が off のときは何も付けない)。

import XCTest
@testable import FTCore

final class OCRShortcutSkipNoteTests: XCTestCase {
    private var source: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/StepExecutor+Assert.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testTheShortcutGateRecordsWhyItWasSkipped() throws {
        let text = source
        XCTAssertFalse(text.isEmpty, "走査対象が読めていない")
        guard let gate = text.range(of: "RegionText.shouldTakeShortcut(mode: occlusionOCRMode"),
              let memo = text.range(of: "let memoKey = VisibilityVerdictMemo.key(", range: gate.upperBound..<text.endIndex)
        else { return XCTFail("近道のゲートか memo の行が見つからない(書式が変わった)") }
        let block = String(text[gate.lowerBound..<memo.lowerBound])
        XCTAssertTrue(block.contains("} else if occlusionOCRMode != .off {"),
                      "OCR が off のときは注記を付けない(利用者が切った近道を「見送った」と言わない)")
        XCTAssertTrue(block.contains(".ocrShortcutBusy : .ocrShortcutNotWarm"),
                      "見送りの理由は warm かどうかで 2 つに分ける")
    }

    func testTheTwoReasonsHaveDistinctTexts() {
        XCTAssertNotEqual(StepNote.ocrShortcutNotWarm.text, StepNote.ocrShortcutBusy.text)
        XCTAssertTrue(StepNote.ocrShortcutNotWarm.text.contains("not warm"))
        XCTAssertTrue(StepNote.ocrShortcutBusy.text.contains("still running"))
    }
}
