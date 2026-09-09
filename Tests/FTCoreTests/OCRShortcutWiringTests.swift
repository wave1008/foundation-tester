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

    func testExecutorPassesTheLiveInFlightCountAndWarmState() throws {
        let text = try String(contentsOf: assertFile, encoding: .utf8)
        let calls = text.components(separatedBy: "RegionText.shouldTakeShortcut(").dropFirst()
        XCTAssertEqual(calls.count, 1, "門の呼び出しは1箇所のはず(増えたらこの走査を広げる)")
        let call = try XCTUnwrap(calls.first)
        let head = String(call.prefix(200))
        XCTAssertTrue(head.contains("warm: RegionText.isWarm"), "warm を生の状態から渡していない: \(head)")
        XCTAssertTrue(head.contains("abandonedInFlight: RegionText.abandonedInFlight"),
                      "諦めた読みの本数を生の値から渡していない(定数だと積み増しが再発する): \(head)")
    }
}
