// 近道(OCR)の門 `RegionText.shouldTakeShortcut` は純粋関数で、**効くかどうかは配線で決まる**。
// 執行器が生の本数(`RegionText.abandonedInFlight`)ではなく定数を渡すと、純粋関数のテストが全部緑のまま
// 積み増しが再発する。配線はソース走査で固定する(OverlayWindowOcclusionWiringTests と同型)。

import Foundation
import XCTest
@testable import FTCore

final class OCRShortcutWiringTests: XCTestCase {

    private var assertFile: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTCore/StepExecutor+Assert.swift")
    }

    func testExecutorPassesTheLiveInFlightCountAndReadyState() throws {
        let text = try String(contentsOf: assertFile, encoding: .utf8)
        let calls = text.components(separatedBy: "RegionText.shouldTakeShortcut(").dropFirst()
        // occlusionFlip の近道と、古いと判定した絵の確認(staleFrameShowsExpectedText)の2箇所。増えたら見直す
        XCTAssertEqual(calls.count, 2, "門の呼び出しの数が変わった(増えた口も生の状態を渡すか見直す)")
        for call in calls {
            let head = String(call.prefix(200))
            XCTAssertTrue(head.contains("ready: RegionText.isModelReady"), "ready を生の状態から渡していない: \(head)")
            XCTAssertTrue(head.contains("abandonedInFlight: RegionText.abandonedInFlight"),
                          "諦めた読みの本数を生の値から渡していない(定数だと積み増しが再発する): \(head)")
        }
    }
}
