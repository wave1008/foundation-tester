// occlusion-guard の OCR 近道を実際に撃つ直前の待ちゲート(RegionText.awaitPrewarm)。
// RegionText.isWarm / abandonedInFlight はプロセス全体の状態で差し替え口が無いので、
// 配線はソース走査で固定する(OCRShortcutWiringTests / OCRShortcutSkipNoteTests と同型)。

import Foundation
import XCTest
@testable import FTCore

final class OCRWarmupWaitGateTests: XCTestCase {

    private var source: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/StepExecutor+Assert.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testWaitsBeforeTheShortcutOnlyWhenNotWarmAndNothingAbandoned() throws {
        let text = source
        XCTAssertFalse(text.isEmpty, "走査対象が読めていない")
        guard let waitCall = text.range(of: "RegionText.awaitPrewarm(mode: occlusionOCRMode)"),
              let shortcutCall = text.range(of: "RegionText.shouldTakeShortcut(mode: occlusionOCRMode")
        else { return XCTFail("待ちゲートか近道ゲートの呼び出しが見つからない(書式が変わった)") }
        XCTAssertLessThan(waitCall.lowerBound, shortcutCall.lowerBound,
                          "待ちは近道のゲートより前で評価する(待った後に isWarm を読み直すため)")

        // 待ちゲートの条件(if の1行)だけを取り出す
        guard let ifRange = text.range(of: "if occlusionOCRMode != .off, RegionText.abandonedInFlight == 0, !RegionText.isWarm {")
        else { return XCTFail("待ちゲートの条件が見つからない(off/busy/warm のどれかを見ていない)") }
        XCTAssertLessThan(ifRange.lowerBound, waitCall.lowerBound, "待ちゲートの条件と呼び出しが対応していない")
    }

    func testWaitedTimeIsChargedToGuardAndOCRPhasesAndNoted() throws {
        let text = source
        guard let waitCall = text.range(of: "let waitOutcome = await RegionText.awaitPrewarm(mode: occlusionOCRMode)"),
              let shortcutCall = text.range(of: "RegionText.shouldTakeShortcut(mode: occlusionOCRMode")
        else { return XCTFail("待ちゲートの呼び出しが見つからない") }
        let block = String(text[waitCall.lowerBound..<shortcutCall.lowerBound])
        XCTAssertTrue(block.contains("phase.guardMs += waitedMs"), "待った時間を guardMs へ計上していない")
        XCTAssertTrue(block.contains("phase.ocrMs += waitedMs"), "待った時間を ocrMs へ計上していない")
        XCTAssertTrue(block.contains(".ocrWarmupWaited"), "待ったことの注記が無い")
        XCTAssertTrue(block.contains("if case .capped = waitOutcome"), "上限に達した場合の分岐が無い")
        XCTAssertTrue(block.contains(".ocrWarmupCapped"), "上限に達したことの注記が無い")
    }
}
